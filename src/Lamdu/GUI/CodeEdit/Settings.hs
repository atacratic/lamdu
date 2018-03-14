{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, OverloadedStrings #-}
module Lamdu.GUI.CodeEdit.Settings
    ( AnnotationMode(..)
    , Settings(..), sAnnotationMode, sSelectedTheme
    , HasSettings(..)
    , eventMap
    , initial
    ) where

import qualified Control.Lens as Lens
import           Data.Property (Property)
import qualified Data.Property as Property
import           GUI.Momentu.EventMap (EventMap)
import qualified GUI.Momentu.State as GuiState
import qualified Lamdu.Config.Sampler as ConfigSampler
import           Lamdu.GUI.CodeEdit.AnnotationMode (AnnotationMode)
import qualified Lamdu.GUI.CodeEdit.AnnotationMode as AnnotationMode
import qualified Lamdu.Themes as Themes

import           Lamdu.Prelude

data Settings = Settings
    { _sAnnotationMode :: AnnotationMode
    , _sSelectedTheme :: Text
    }
Lens.makeLenses ''Settings

initial :: Settings
initial =
    Settings
    { _sAnnotationMode = AnnotationMode.initial
    , _sSelectedTheme = Themes.initial
    }

class HasSettings env where settings :: Lens' env Settings

eventMap ::
    ConfigSampler.Sampler -> Property IO Settings ->
    IO (EventMap (IO GuiState.Update))
eventMap configSampler settingsProp =
    do
        config <- ConfigSampler.getSample configSampler <&> (^. ConfigSampler.sConfig)
        let themeSwitch = Themes.switchEventMap configSampler themeProp config
        let switchAnnotationMode = AnnotationMode.switchEventMap annotationModeProp config
        themeSwitch <> switchAnnotationMode & pure
    where
        themeProp = Property.composeLens sSelectedTheme settingsProp
        annotationModeProp = Property.composeLens sAnnotationMode settingsProp
