{-# LANGUAGE DeriveAnyClass   #-}
{-# LANGUAGE DeriveGeneric    #-}
{-# LANGUAGE PatternSynonyms  #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
-- |
-- Module      : Data.Array.Accelerate.Data.HashMap
-- Copyright   : [2020] Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.Data.HashMap (

  HashMap, Hashable,

  -- * Basic interface
  size,
  member,
  lookup,
  -- insert,
  -- alter,

  -- * Transformations
  map,
  mapWithKey,

  -- * Conversions
  keys,
  elems,

  -- * Arrays
  fromVector,
  toVector,

) where

import Data.Array.Accelerate                              hiding ( size, map )
import Data.Array.Accelerate.Data.Functor
import Data.Array.Accelerate.Unsafe
import Data.Array.Accelerate.Data.Bits
import Data.Array.Accelerate.Data.Maybe
import qualified Data.Array.Accelerate                    as A

import Data.Array.Accelerate.Data.Hashable
import Data.Array.Accelerate.Data.Tree.Radix
import Data.Array.Accelerate.Data.Sort.Quick

import Data.Function


-- | A map from keys to values. The map can not contain duplicate keys.
--
data HashMap k v = HashMap (Vector Node) (Vector (k,v))
  deriving (Show, Generic, Arrays)

pattern HashMap_
    :: (Elt k, Elt v)
    => Acc (Vector Node)    -- tree structure
    -> Acc (Vector (k,v))   -- (key,value) pairs
    -> Acc (HashMap k v)
pattern HashMap_ t kv = Pattern (t,kv)
{-# COMPLETE HashMap_ #-}


-- | /O(1)/ Return the number of key-value mappings
--
size :: (Elt k, Elt v) => Acc (HashMap k v) -> Exp Int
size (HashMap_ _ kv) = length kv

-- | /O(k)/ Return 'True' if the specified key is present in the map,
-- 'False' otherwise
--
member :: (Eq k, Hashable k, Elt v) => Exp k -> Acc (HashMap k v) -> Exp Bool
member k m =
  if isJust (lookup k m)
     then True_
     else False_

-- | /O(k)/ Return the value to which the specified key is mapped, or
-- 'Nothing' if the map contains no mapping for the key.
--
lookup :: (Eq k, Hashable k, Elt v) => Exp k -> Acc (HashMap k v) -> Exp (Maybe v)
lookup k hm = snd `fmap` lookupWithIndex k hm

lookupWithIndex :: (Eq k, Hashable k, Elt v) => Exp k -> Acc (HashMap k v) -> Exp (Maybe (Int, v))
lookupWithIndex key (HashMap_ tree kv) = result
  where
    h                 = hash key
    n                 = length tree
    bits              = finiteBitSize (undef @Key)
    index  (Ptr_ x)   = clearBit x (bits - 1)
    isLeaf (Ptr_ x)   = testBit  x (bits - 1)

    T2 _ result       = while (\(T2 i _) -> i < n) step (T2 0 Nothing_)
    step (T2 i _)     =
      let Node_ d l r _p = tree !! i
          d'             = fromIntegral d
       in if d' < bits
             then let m = testBit h (bits - d' - 1) ? (r, l)
                      j = index m
                   in if isLeaf m
                         then let T2 k v = kv !! j
                               in T2 n (k == key ? (Just_ (T2 j v), Nothing_))
                         else T2 j Nothing_
             else
               -- TODO: there was a hash collision
              T2 n Nothing_


-- | /O(n)/ Transform the map by applying a function to every value
--
map :: (Elt k, Elt v1, Elt v2) => (Exp v1 -> Exp v2) -> Acc (HashMap k v1) -> Acc (HashMap k v2)
map f = mapWithKey (const f)

-- | /O(n)/ Transform this map by applying a function to every value
--
mapWithKey :: (Elt k, Elt v1, Elt v2) => (Exp k -> Exp v1 -> Exp v2) -> Acc (HashMap k v1) -> Acc (HashMap k v2)
mapWithKey f (HashMap_ t kv)
  = HashMap_ t
  $ A.map (\(T2 k v) -> T2 k (f k v)) kv

-- | /O(1)/ Return this map's keys
--
keys :: (Elt k, Elt v) => Acc (HashMap k v) -> Acc (Vector k)
keys (HashMap_ _ kv) = A.map fst kv

-- | /O(1)/ Return this map's values
--
elems :: (Elt k, Elt v) => Acc (HashMap k v) -> Acc (Vector v)
elems (HashMap_ _ kv) = A.map snd kv

-- | /O(n log n)/ Construct a map from the supplied (key,value) pairs
--
fromVector :: (Hashable k, Elt v) => Acc (Vector (k,v)) -> Acc (HashMap k v)
fromVector assocs = HashMap_ tree kv
  where
    tree    = binary_radix_tree h
    (h, kv) = unzip
            . quicksortBy (compare `on` fst)
            $ A.map (\(T2 k v) -> T2 (bitcast (hash k)) (T2 k v)) assocs

-- | /O(1)/ Return this map's (key,value) pairs
--
toVector :: (Elt k, Elt v) => Acc (HashMap k v) -> Acc (Vector (k,v))
toVector (HashMap_ _ kv) = kv
