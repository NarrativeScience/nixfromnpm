{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
module Filesystem.Path.Wrappers where

import ClassyPrelude hiding (FilePath, unpack)
import qualified ClassyPrelude as CP
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.Text hiding (map)
import System.Directory (Permissions(..))
import qualified System.Directory as Dir
import qualified System.Posix.Files as Posix
import Filesystem.Path.CurrentOS
import Control.Monad.Trans.Control
import Control.Exception.Lifted
import qualified Paths_nixfromnpm as Paths

import qualified Nix.Types as Nix

-- | Take a function that takes a string path and returns something, and
-- turn it into a function that operates in any MonadIO and takes a FilePath.
generalize :: MonadIO io => (CP.FilePath -> IO a) -> FilePath -> io a
generalize action = liftIO . action . pathToString

-- | Makes a nix regular path expression from a filepath.
mkPath :: FilePath -> Nix.NExpr
mkPath = Nix.mkPath False . pathToString

-- | Makes a nix regular path expression from a filepath.
mkEnvPath :: FilePath -> Nix.NExpr
mkEnvPath = Nix.mkPath True . pathToString

-- | Wraps a function generated by cabal. Returns path to a data file.
getDataFileName :: MonadIO io => FilePath -> io FilePath
getDataFileName = map decodeString . generalize Paths.getDataFileName

-- | Write some stuff to disk.
writeFile :: (MonadIO io, IOData dat) => FilePath -> dat -> io ()
writeFile path = CP.writeFile (pathToString path)

-- | Read a file from disk.
readFile :: (MonadIO io, IOData dat) => FilePath -> io dat
readFile = generalize CP.readFile

-- | Create a symbolic link at `path2` pointing to `path1`.
createSymbolicLink :: (MonadIO io) => FilePath -> FilePath -> io ()
createSymbolicLink path1 path2 = liftIO $ do
  Posix.createSymbolicLink (pathToString path1) (pathToString path2)

-- | Convert a FilePath into Text.
pathToText :: FilePath -> Text
pathToText pth = case toText pth of
  Left p -> p
  Right p -> p

-- | Convert a FilePath into a string.
pathToString :: FilePath -> String
pathToString = unpack . pathToText

-- | Perform an IO action inside of the given directory. Catches exceptions.
withDir :: (MonadBaseControl IO io, MonadIO io)
        => FilePath -> io a -> io a
withDir directory action = do
  cur <- getCurrentDirectory
  bracket_ (setCurrentDirectory directory)
           (setCurrentDirectory cur)
           action

takeBaseName :: FilePath -> Text
takeBaseName = pathToText . basename

createDirectoryIfMissing :: MonadIO m => FilePath -> m ()
createDirectoryIfMissing = liftIO . Dir.createDirectoryIfMissing True .
                             pathToString

doesDirectoryExist :: MonadIO m => FilePath -> m Bool
doesDirectoryExist = liftIO . Dir.doesDirectoryExist . pathToString

doesFileExist :: MonadIO m => FilePath -> m Bool
doesFileExist = liftIO . Dir.doesFileExist . pathToString

doesPathExist :: MonadIO m => FilePath -> m Bool
doesPathExist path = doesFileExist path >>= \case
  True -> return True
  False -> doesDirectoryExist path

getCurrentDirectory :: MonadIO m => m FilePath
getCurrentDirectory = decodeString <$> liftIO Dir.getCurrentDirectory

removeDirectoryRecursive :: MonadIO m => FilePath -> m ()
removeDirectoryRecursive = liftIO . Dir.removeDirectoryRecursive . pathToString

removeFile :: MonadIO m => FilePath -> m ()
removeFile = liftIO . Dir.removeFile . pathToString

getDirectoryContents :: MonadIO m => FilePath -> m [FilePath]
getDirectoryContents dir = do
  contents <- liftIO $ Dir.getDirectoryContents $ pathToString dir
  return $ map decodeString contents

hasExt :: Text -> FilePath -> Bool
hasExt ext path = case extension path of
  Just ext' | ext == ext' -> True
  otherwise -> False

setCurrentDirectory :: MonadIO io => FilePath -> io ()
setCurrentDirectory = liftIO . Dir.setCurrentDirectory . pathToString

getPermissions :: MonadIO io => FilePath -> io Permissions
getPermissions = generalize Dir.getPermissions

isWritable :: MonadIO io => FilePath -> io Bool
isWritable = map writable . getPermissions
