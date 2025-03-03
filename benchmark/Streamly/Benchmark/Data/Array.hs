-- |
-- Module      : Main
-- Copyright   : (c) 2020 Composewell Technologies
--
-- License     : BSD-3-Clause
-- Maintainer  : streamly@composewell.com

{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}

import Control.DeepSeq (NFData(..))
import System.Random (randomRIO)

import qualified Streamly.Benchmark.Data.ArrayOps as Ops
import qualified Streamly.Data.Array.Foreign as A

#ifdef DATA_ARRAY
import qualified Streamly.Internal.Data.Array as IA
#else
import qualified Streamly.Internal.Data.Array.Foreign as IA
#endif
import qualified Streamly.Prelude  as S

import Gauge
import Streamly.Benchmark.Common hiding (benchPureSrc)
import qualified Streamly.Benchmark.Prelude as P

#ifdef MEMORY_ARRAY
import qualified GHC.Exts as GHC
#endif

#if !defined(DATA_ARRAY_PRIM) && !defined(DATA_ARRAY_PRIM_PINNED)
import Control.DeepSeq (deepseq)
#endif

-------------------------------------------------------------------------------
--
-------------------------------------------------------------------------------

#ifdef MEMORY_ARRAY
-- Drain a source that generates a pure array
{-# INLINE benchPureSrc #-}
benchPureSrc :: String -> (Int -> Ops.Stream a) -> Benchmark
benchPureSrc name src = benchPure name src id
#endif

{-# INLINE benchIO #-}
benchIO :: NFData b => String -> (Int -> IO a) -> (a -> b) -> Benchmark
benchIO name src f = bench name $ nfIO $
    randomRIO (1,1) >>= src >>= return . f

-- Drain a source that generates an array in the IO monad
{-# INLINE benchIOSrc #-}
benchIOSrc ::
#if !defined(DATA_ARRAY_PRIM) \
    && !defined(DATA_ARRAY_PRIM_PINNED) \
    && !defined(MEMORY_ARRAY)
       NFData a =>
#endif
       String -> (Int -> IO (Ops.Stream a)) -> Benchmark
benchIOSrc name src = benchIO name src id

{-# INLINE benchPureSink #-}
benchPureSink :: NFData b => Int -> String -> (Ops.Stream Int -> b) -> Benchmark
benchPureSink value name f = benchIO name (Ops.sourceIntFromTo value) f

{-# INLINE benchIO' #-}
benchIO' :: NFData b => String -> (Int -> IO a) -> (a -> IO b) -> Benchmark
benchIO' name src f = bench name $ nfIO $
    randomRIO (1,1) >>= src >>= f

{-# INLINE benchIOSink #-}
benchIOSink :: NFData b => Int -> String -> (Ops.Stream Int -> IO b) -> Benchmark
benchIOSink value name f = benchIO' name (Ops.sourceIntFromTo value) f

o_1_space_generation :: Int -> [Benchmark]
o_1_space_generation value =
    [ bgroup
        "generation"
        [ benchIOSrc "writeN . intFromTo" (Ops.sourceIntFromTo value)
#ifndef DATA_SMALLARRAY
        , benchIOSrc "write . intFromTo" (Ops.sourceIntFromToFromStream value)
#endif
        , benchIOSrc
              "fromList . intFromTo"
              (Ops.sourceIntFromToFromList value)
        , benchIOSrc "writeN . unfoldr" (Ops.sourceUnfoldr value)
        , benchIOSrc "writeN . fromList" (Ops.sourceFromList value)
#ifdef MEMORY_ARRAY
        , benchPureSrc "writeN . IsList.fromList" (Ops.sourceIsList value)
        , benchPureSrc
              "writeN . IsString.fromString"
              (Ops.sourceIsString value)
#endif
#if !defined(DATA_ARRAY_PRIM) && !defined(DATA_ARRAY_PRIM_PINNED)
#ifdef DATA_SMALLARRAY
        , let testStr =
                  "fromListN " ++
                  show (value + 1) ++
                  "[1" ++ concat (replicate value ",1") ++ "]"
#else
        , let testStr = mkListString value
#endif
           in testStr `deepseq` (bench "read" $ nf Ops.readInstance testStr)
#endif
        , benchPureSink value "show" Ops.showInstance
        ]
    ]

o_1_space_elimination :: Int -> [Benchmark]
o_1_space_elimination value =
    [ bgroup "elimination"
        [ benchPureSink value "id" id
        , benchPureSink value "==" Ops.eqInstance
        , benchPureSink value "/=" Ops.eqInstanceNotEq
        , benchPureSink value "<" Ops.ordInstance
        , benchPureSink value "min" Ops.ordInstanceMin
#ifdef MEMORY_ARRAY
        -- length is used to check for foldr/build fusion
        , benchPureSink value "length . IsList.toList" (length . GHC.toList)
#endif
        , benchIOSink value "foldl'" Ops.pureFoldl'
        , benchIOSink value "read" Ops.unfoldReadDrain
        , benchIOSink value "toStreamRev" Ops.toStreamRevDrain
        , benchFold "writeLastN.1"
            (S.fold (IA.writeLastN 1)) (P.sourceUnfoldrM value)
        , benchFold "writeLastN.10"
            (S.fold (IA.writeLastN 10)) (P.sourceUnfoldrM value)
#if !defined(DATA_ARRAY_PRIM) && !defined(DATA_ARRAY_PRIM_PINNED)
#ifdef DEVBUILD
{-
        , benchPureSink value "foldable/foldl'" Ops.foldableFoldl'
        , benchPureSink value "foldable/sum" Ops.foldableSum
-}
#endif
#endif
        ]
      ]

o_n_heap_serial :: Int -> [Benchmark]
o_n_heap_serial value =
    [ bgroup "elimination"
        [
        -- Converting the stream to an array
            benchFold "writeLastN.Max" (S.fold (IA.writeLastN (value + 1)))
                (P.sourceUnfoldrM value)
            , benchFold "writeN" (S.fold (A.writeN value))
                (P.sourceUnfoldrM value)
         ]
    ]

o_1_space_transformation :: Int -> [Benchmark]
o_1_space_transformation value =
   [ bgroup "transformation"
        [ benchIOSink value "scanl'" (Ops.scanl' value 1)
        , benchIOSink value "scanl1'" (Ops.scanl1' value 1)
        , benchIOSink value "map" (Ops.map value 1)
        ]
   ]

o_1_space_transformationX4 :: Int -> [Benchmark]
o_1_space_transformationX4 value =
    [ bgroup "transformationX4"
        [ benchIOSink value "scanl'" (Ops.scanl' value 4)
        , benchIOSink value "scanl1'" (Ops.scanl1' value 4)
        , benchIOSink value "map" (Ops.map value 4)
        ]
      ]

moduleName :: String
#ifdef DATA_SMALLARRAY
moduleName = "Data.SmallArray"
#elif defined(MEMORY_ARRAY)
moduleName = "Data.Array.Foreign"
#elif defined(DATA_ARRAY_PRIM)
moduleName = "Data.Array.Prim"
#elif defined(DATA_ARRAY_PRIM_PINNED)
moduleName = "Data.Array.Prim.Pinned"
#else
moduleName = "Data.Array"
#endif

#ifdef DATA_SMALLARRAY
defStreamSize :: Int
defStreamSize = 128
#else
defStreamSize :: Int
defStreamSize = defaultStreamSize
#endif

main :: IO ()
main = runWithCLIOpts defStreamSize allBenchmarks

    where

    allBenchmarks size =
        [ bgroup (o_1_space_prefix moduleName) $ concat
            [ o_1_space_generation size
            , o_1_space_elimination size
            , o_1_space_transformation size
            , o_1_space_transformationX4 size
            ]
        , bgroup (o_n_space_prefix moduleName) $
             o_n_heap_serial size
        ]
