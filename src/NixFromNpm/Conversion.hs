{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
module NixFromNpm.Conversion where

import qualified Prelude as P
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as H
import Data.Map (Map)
import qualified Data.Map as M
import Data.Text (Text)
import qualified Data.Text as T
import Text.Printf (printf)
import Shelly (shelly, cp_r)


import qualified Paths_nixfromnpm
import NixFromNpm.Common
import Nix.Types
import Nix.Parser
import Nix.Pretty (prettyNix)
import NixFromNpm.ConvertToNix (toDotNix,
                                rootDefaultNix,
                                defaultNixExtending,
                                packageJsonDefaultNix,
                                resolvedPkgToNix,
                                nodePackagesDir)
import NixFromNpm.Options
import NixFromNpm.NpmTypes
import NixFromNpm.SemVer
import NixFromNpm.Parsers.SemVer
import NixFromNpm.PackageMap (PackageMap, pmLookup, pmDelete, pmMap)
import NixFromNpm.NpmLookup (FullyDefinedPackage(..),
                             NpmFetcher(..),
                             NpmFetcherSettings(..),
                             NpmFetcherState(..),
                             addPackage, rmPackage,
                             toFullyDefined,
                             startState,
                             runNpmFetchWith,
                             resolveNpmVersionRange,
                             resolveVersionInfoFull,
                             defaultSettings,
                             PreExistingPackage(..))

-- | The npm lookup utilities will produce a bunch of fully defined packages.
-- However, the only packages that we want to write are the new ones; that
-- is, the ones that we've discovered and the ones that already exist. This
-- will perform the appropriate filter. It will also convert them to nix.
takeNewPackages :: PackageMap FullyDefinedPackage
                -> PackageMap NExpr
takeNewPackages startingRec = do
  let isNew (NewPackage rpkg) = Just $ resolvedPkgToNix rpkg
      isNew _ = Nothing
  H.filter (not . H.null) $ H.map (modifyMap isNew) startingRec

-- | Given the path to a package, finds all of the .nix files which parse
--   correctly.
parseVersion :: MonadIO io => Name -> FilePath -> io (Maybe (SemVer, NExpr))
parseVersion pkgName path = do
  let (versionTxt, ext) = splitExtension $ filename path
  case parseSemVer (pathToText versionTxt) of
    _ | ext /= Just "nix" -> return Nothing -- not a nix file
    Left _ -> return Nothing -- not a version file
    Right version -> parseNixString . pack <$> readFile path >>= \case
      Failure err -> do
        putStrsLn ["Warning: expression for ", pkgName, " version ",
                   pathToText versionTxt, " failed to parse:\n", pshow err]
        return Nothing -- invalid nix, should overwrite
      Success expr -> return $ Just (version, expr)

-- | Given the path to a file possibly containing nix expressions, finds all
--   expressions findable at that path and returns a map of them.
findExisting :: (MonadBaseControl IO io, MonadIO io)
             => Maybe Name -- ^ Is `Just` if this is an extension.
             -> FilePath       -- ^ The path to search.
             -> io (PackageMap PreExistingPackage) -- ^ Mapping of package
                                                   --   names to maps of
                                                   --   versions to nix
                                                   --   expressions.
findExisting maybeName path = do
  doesDirectoryExist (path </> nodePackagesDir) >>= \case
    False -> case maybeName of
      Just name -> errorC [
        "Path ", pathToText path, " does not exist or does not ",
        "contain a `", pathToText nodePackagesDir, "` folder"]
      Nothing -> return mempty
    True -> withDir (path </> nodePackagesDir) $ do
      let wrapper = maybe FromOutput FromExtension maybeName
      putStrsLn ["Searching for existing expressions in ", pathToText path,
                 "..."]
      contents <- getDirectoryContents "."
      verMaps <- map catMaybes $ forM contents $ \dir -> do
        exprs <- doesDirectoryExist dir >>= \case
          True -> withDir dir $ do
            contents <- getDirectoryContents "."
            let files = filter (hasExt "nix") contents
            catMaybes <$> mapM (parseVersion $ pathToText dir) files
          False -> do
            return mempty -- not a directory
        return $ case exprs of
          [] -> Nothing
          vs -> Just (pathToText dir, H.map wrapper $ H.fromList exprs)
      let total = sum $ map (H.size . snd) verMaps
      putStrsLn ["Found ", render total, " expressions in ", pathToText path]
      return $ H.fromList verMaps

-- | Given the output directory and any number of extensions to load,
-- finds any existing packages.
preloadPackages :: NpmFetcher () -- ^ Add the existing packages to the state.
preloadPackages = do
  existing <- asks nfsCacheDepth >>= \case
    n | n < 0 -> return mempty
      | otherwise -> findExisting Nothing =<< asks nfsOutputPath
  toExtend <- asks nfsExtendPaths
  libraries <- fmap concat $ forM (H.toList toExtend) $ \(name, path) -> do
    findExisting (Just name) path
  let all = existing <> libraries
  modify $ \s -> s {
    resolved = pmMap toFullyDefined all <> resolved s
    }

-- | Initialize an output directory from scratch. This means:
-- * Creating a .nixfromnpm-version file storing the current version.
-- * Copying over the nix node libraries that nixfromnpm provides.
-- * Creating a default.nix file.
-- * Creating a nodePackages folder.
initializeOutput :: NpmFetcher ()
initializeOutput = do
  outputPath <- asks nfsOutputPath
  extensions <- asks nfsExtendPaths
  createDirectoryIfMissing outputPath
  withDir outputPath $ do
    putStrsLn ["Initializing  ", pathToText outputPath]
    version <- case fromHaskellVersion Paths_nixfromnpm.version of
      Left err -> fatal ("When parsing version: " <> err)
      Right v -> return v
    writeFile ".nixfromnpm-version" $ renderSV version
    case H.keys extensions of
      [] -> do -- Then we are creating a new root.
        writeNix "default.nix" rootDefaultNix
        putStrsLn ["Generating node libraries in ", pathToText outputPath]
        pth <- getDataFileName "nix-libs"
        shelly $ do
          cp_r (pth </> "buildNodePackage") outputPath
          cp_r (pth </> "nodeLib") outputPath
      (extName:_) -> do -- Then we are extending things.
        writeNix "default.nix" $ defaultNixExtending extName extensions

-- | Convenience function to write a nix expression to the given path.
writeNix :: MonadIO io => FilePath -> NExpr -> io ()
writeNix path = writeFile path . show . prettyNix

-- | Actually writes the packages to disk. Takes in the new packages to write,
--   and the names/paths to the libraries being extended.
writeNewPackages :: NpmFetcher ()
writeNewPackages = takeNewPackages <$> gets resolved >>= \case
  newPackages
    | H.null newPackages -> putStrLn "No library packages created."
    | otherwise -> do
      outputPath <- asks nfsOutputPath
      let path = outputPath </> nodePackagesDir
      putStrsLn ["Creating new packages at ", pathToText path]
      withDir path $ do
        -- Write the .nix file for each version of this package.
        forM_ (H.toList newPackages) $ \(pkgName, pkgVers) -> do
          let subdir = path </> fromText pkgName
          createDirectoryIfMissing subdir
          withDir subdir $ do
            -- Write all of the versions we have generated.
            forM_ (H.toList pkgVers) $ \(ver, expr) -> do
              let fullPath = subdir </> toDotNix ver
              putStrsLn ["Writing package file at ", pathToText fullPath]
              writeNix (toDotNix ver) expr
            -- Remove the `latest.nix` symlink if it exists.
            whenM (doesFileExist "latest.nix") $ removeFile "latest.nix"
            -- Grab the latest version and create a symlink `latest.nix`
            -- to that.
            let convert fname =
                  case parseSemVer (T.dropEnd 4 $ pathToText fname) of
                    Left _ -> Nothing -- not a semver, so we don't consider it
                    Right ver -> Just ver -- return the version
            allVersions <- catMaybes . map convert <$> getDirectoryContents "."
            createSymbolicLink (toDotNix $ maximum allVersions) "latest.nix"

-- | Load all of the expressions from a package.json's dependencies,
-- including dev dependencies. Generate nix files for that package.
convertPackageJson :: FilePath
                   -- ^ Path to folder containing package.json.
                   -> VersionInfo -- ^ Parsed VersionInfo.
                   -> NpmFetcher ()
convertPackageJson path verinfo = do
  let (name, version) = (viName verinfo, viVersion verinfo)
  putStrsLn ["Generating expression for package ", name,
             ", version ", renderSV version]
  -- "Pretend" that we've never loaded this file up, even if
  -- we have. This will force the generated file to be a new
  -- package.
  storedResolved <- gets resolved
  -- storedResolved might contain this package.
  modify $ \s -> s {resolved = pmDelete name version (resolved s)}
  -- now our state definitely does not. Resolve the version info.
  rPkg <- snd <$> resolveVersionInfoFull verinfo
  case pmLookup name version storedResolved of
    -- If we had a previous version, restore it here.
    Just existing -> addPackage name version existing
    -- Otherwise, remove the one we just created because we
    -- don't want to write it to the package store.
    Nothing -> rmPackage name version
  withDir path $ do
    outputPath <- asks nfsOutputPath
    putStrsLn ["Writing package nix files at ", pathToText path]
    writeNix "project.nix" $ resolvedPkgToNix rPkg
    writeNix "default.nix" $ packageJsonDefaultNix outputPath

-- | Top-level entry point for generating expressions from the
-- command-line. Fetches all given packages and dependencies of
-- package.json files, and writes them to disk.
generateExpressions :: NixFromNpmOptions -> IO ()
generateExpressions (opts@NixFromNpmOptions{..}) = do
  let settings = defaultSettings {
    nfsGithubAuthToken = nfnoGithubToken,
    nfsRegistries = nfnoRegistries,
    nfsRequestTimeout = fromIntegral nfnoTimeout,
    nfsOutputPath = nfnoOutputPath,
    nfsExtendPaths = nfnoExtendPaths,
    nfsMaxDevDepth = nfnoDevDepth,
    nfsCacheDepth = nfnoCacheDepth
    }
  runNpmFetchWith settings startState $ do
    preloadPackages
    initializeOutput
    forM nfnoPkgNames $ \(name, range) -> do
      (resolveNpmVersionRange name range >> return ())
        `catch` \(e :: SomeException) -> do
          warns ["Failed to build ", name, "@", pshow range, ": ", pshow e]
      writeNewPackages
    forM nfnoPkgPaths $ \(path, verInfo) -> do
      convertPackageJson path verInfo
      writeNewPackages
  return ()
