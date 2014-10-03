{-# LANGUAGE CPP, BangPatterns #-}

module Language.Haskell.GhcMod.Find
#ifndef SPEC
  (
    Symbol
  , SymbolDb
  , loadSymbolDb
  , lookupSymbol
  , dumpSymbol
  , findSymbol
  , lookupSym
  , isOutdated
  )
#endif
  where

import Control.Applicative ((<$>))
import Control.Monad (when, void)
import Control.Monad.Error.Class
import Data.Function (on)
import Data.List (groupBy, sort)
import Data.Maybe (fromMaybe)
import qualified GHC as G
import Language.Haskell.GhcMod.Convert
import Language.Haskell.GhcMod.GhcPkg
import Language.Haskell.GhcMod.Monad
import Language.Haskell.GhcMod.Types
import Language.Haskell.GhcMod.Utils
import Name (getOccString)
import System.Directory (doesFileExist, getModificationTime)
import System.FilePath ((</>), takeDirectory)
import System.IO

#ifndef MIN_VERSION_containers
#define MIN_VERSION_containers(x,y,z) 1
#endif

#if MIN_VERSION_containers(0,5,0)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
#else
import Data.Map (Map)
import qualified Data.Map as M
#endif

----------------------------------------------------------------

-- | Type of function and operation names.
type Symbol = String
-- | Database from 'Symbol' to \['ModuleString'\].
data SymbolDb = SymbolDb {
    table :: Map Symbol [ModuleString]
  , packageCachePath :: FilePath
  , symbolDbCachePath :: FilePath
  } deriving (Show)

isOutdated :: SymbolDb -> IO Bool
isOutdated db = symbolDbCachePath db `isOlderThan` packageCachePath db

----------------------------------------------------------------

-- | When introducing incompatible changes to the 'symbolCache' file format
-- increment this version number.
symbolCacheVersion :: Integer
symbolCacheVersion = 0

-- | Filename of the symbol table cache file.
symbolCache :: String
symbolCache = "ghc-mod-"++ show symbolCacheVersion ++".cache"

----------------------------------------------------------------

-- | Looking up 'SymbolDb' with 'Symbol' to \['ModuleString'\]
--   which will be concatenated. 'loadSymbolDb' is called internally.
findSymbol :: IOish m => Symbol -> GhcModT m String
findSymbol sym = loadSymbolDb >>= lookupSymbol sym

-- | Looking up 'SymbolDb' with 'Symbol' to \['ModuleString'\]
--   which will be concatenated.
lookupSymbol :: IOish m => Symbol -> SymbolDb -> GhcModT m String
lookupSymbol sym db = convert' $ lookupSym sym db

lookupSym :: Symbol -> SymbolDb -> [ModuleString]
lookupSym sym db = fromMaybe [] $ M.lookup sym $ table db

---------------------------------------------------------------

-- | Loading a file and creates 'SymbolDb'.
loadSymbolDb :: (IOish m, MonadError GhcModError m) => m SymbolDb
loadSymbolDb = do
    ghcMod <- liftIO ghcModExecutable
    file <- chop <$> readProcess' ghcMod ["dumpsym"]
    !db <- M.fromAscList . map conv . lines <$> liftIO (readFile file)
    return $ SymbolDb {
        table = db
      , packageCachePath = takeDirectory file </> packageCache
      , symbolDbCachePath = file
      }
  where
    conv :: String -> (Symbol,[ModuleString])
    conv = read
    chop "" = ""
    chop xs = init xs

----------------------------------------------------------------
-- used 'ghc-mod dumpsym'

-- | Dumping a set of ('Symbol',\['ModuleString'\]) to a file
--   if the file does not exist or is invalid.
--   The file name is printed.

dumpSymbol :: IOish m => GhcModT m String
dumpSymbol = do
    crdl <- cradle
    dir <- liftIO $ getPackageCachePath crdl
    let cache = dir </> symbolCache
        pkgdb = dir </> packageCache

    create <- liftIO $ cache `isOlderThan` pkgdb
    when create $ (liftIO . writeSymbolCache cache) =<< getSymbolTable
    return $ unlines [cache]

writeSymbolCache :: FilePath
                 -> [(Symbol,[ModuleString])]
                 -> IO ()
writeSymbolCache cache sm =
  void . withFile cache WriteMode $ \hdl ->
      mapM (hPrint hdl) sm

isOlderThan :: FilePath -> FilePath -> IO Bool
isOlderThan cache file = do
    exist <- doesFileExist cache
    if not exist then
        return True
      else do
        tCache <- getModificationTime cache
        tFile <- getModificationTime file
        return $ tCache <= tFile -- including equal just in case

-- | Browsing all functions in all system/user modules.
getSymbolTable :: IOish m => GhcModT m [(Symbol,[ModuleString])]
getSymbolTable = do
    ghcModules <- G.packageDbModules True
    moduleInfos <- mapM G.getModuleInfo ghcModules
    let modules = do
         m <- ghcModules
         let moduleName = G.moduleNameString $ G.moduleName m
--             modulePkg = G.packageIdString $ G.modulePackageId m
         return moduleName

    return $ collectModules
           $ extractBindings `concatMap` (moduleInfos `zip` modules)

extractBindings :: (Maybe G.ModuleInfo, ModuleString)
                -> [(Symbol, ModuleString)]
extractBindings (Nothing,_)  = []
extractBindings (Just inf,mdlname) =
    map (\name -> (getOccString name, mdlname)) names
  where
    names = G.modInfoExports inf

collectModules :: [(Symbol,ModuleString)]
               -> [(Symbol,[ModuleString])]
collectModules = map tieup . groupBy ((==) `on` fst) . sort
  where
    tieup x = (head (map fst x), map snd x)
