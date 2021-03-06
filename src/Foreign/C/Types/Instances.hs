{-# OPTIONS -fno-warn-orphans #-}
module Foreign.C.Types.Instances () where

import Data.Aeson (ToJSON(..), FromJSON(..))
import Foreign.C.Types (CDouble)

import Prelude

instance FromJSON CDouble where
    parseJSON = fmap (realToFrac :: Double -> CDouble) . parseJSON
instance ToJSON CDouble where
    toJSON = toJSON . (realToFrac :: CDouble -> Double)
