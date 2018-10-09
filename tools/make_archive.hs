#!/usr/bin/env runhaskell

import           Control.Exception (bracket_)
import qualified System.Directory as Dir
import qualified System.Environment as Env
import           System.FilePath ((</>), takeFileName, takeDirectory)
import qualified System.NodeJS.Path as NodeJS
import           System.Process (readProcess, callProcess)

import           Lamdu.Prelude

-- ldd example output:
-- 	linux-vdso.so.1 (0x00007ffc97d9f000)
-- 	libm.so.6 => /lib/x86_64-linux-gnu/libm.so.6 (0x00007f5a328be000)
-- 	libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1 (0x00007f5a326a1000)
-- 	libleveldb.so.1 => /usr/lib/x86_64-linux-gnu/libleveldb.so.1 (0x00007f5a32444000)
--      ...
-- 	/lib64/ld-linux-x86-64.so.2 (0x00007f5a32c5c000)
--      ...
-- 	libXau.so.6 => /usr/lib/x86_64-linux-gnu/libXau.so.6 (0x00007f5a2e134000)
-- 	libXdmcp.so.6 => /usr/lib/x86_64-linux-gnu/libXdmcp.so.6 (0x00007f5a2df2e000)
-- 	libbsd.so.0 => /lib/x86_64-linux-gnu/libbsd.so.0 (0x00007f5a2dd19000)

-- full listing of ldd deps that have files:
--   libm
--   libz
--   libleveldb
--   libGLEW
--   libGLU
--   libGL
--   libX11
--   libXi
--   libXrandr
--   libXxf86vm
--   libXcursor
--   libXinerama
--   libpthread
--   librt
--   libutil
--   libdl
--   libgmp
--   libelf
--   libdw
--   libc
--   libsnappy
--   libstdc++
--   libgcc
--   libGLX
--   libGLdispatch
--   libxcb
--   libXext
--   libXrender
--   libXfixes
--   liblzma
--   libbz2
--   libXau
--   libXdmcp
--   libbsd

interestingLibs :: [String]
interestingLibs =
    [ "libleveldb"
    , "libgmp"
    , "libelf"
    , "libdw"
    , "libsnappy"
    , "liblzma"
    , "libbz2"
    , "libbsd"
    ]

isInteresting :: FilePath -> Bool
isInteresting path =
    baseName `elem` interestingLibs
    where
        -- takeBaseName removes one extension, we remove all:
        baseName = takeFileName path & break (== '.') & fst

parseLddOut :: String -> [FilePath]
parseLddOut lddOut =
    lines lddOut
    >>= parseLine
    where
        parseLine line =
            case words line & break (== "=>") & snd of
            [] -> []
            "=>":libPath:_ -> [libPath]
            _ -> error "unexpected break output"

pkgDir :: FilePath
pkgDir = "lamdu"

toPackageWith :: FilePath -> FilePath -> IO ()
toPackageWith srcPath relPath =
    do
        putStrLn $ "Packaging " ++ srcPath ++ " to " ++ destPath
        Dir.createDirectoryIfMissing True (takeDirectory destPath)
        callProcess "cp" ["-aLr", srcPath, destPath]
    where
        destPath = pkgDir </> relPath

toPackage :: FilePath -> IO ()
toPackage srcPath = toPackageWith srcPath (takeFileName srcPath)

libToPackage :: FilePath -> IO ()
libToPackage srcPath = toPackageWith srcPath ("lib" </> takeFileName srcPath)

createTempDir :: FilePath -> IO a -> IO a
createTempDir dir =
    bracket_ (Dir.createDirectory dir) (Dir.removeDirectoryRecursive dir)

main :: IO ()
main =
    do
        [lamduExec] <- Env.getArgs
        dependencies <- readProcess "ldd" [lamduExec] "" <&> parseLddOut
        createTempDir pkgDir $ do
            toPackageWith lamduExec "bin/lamdu"
            toPackage "data"
            toPackage "tools/run-lamdu.sh"
            nodePath <- NodeJS.path
            toPackageWith nodePath "data/bin/node"
            filter isInteresting dependencies & mapM_ libToPackage
            callProcess "tar" ["-c", "-z", "-f", "lamdu.tgz", pkgDir]