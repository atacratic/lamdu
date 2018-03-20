module Lamdu.GUI.LightLambda
    ( withUnderline
    ) where

import           GUI.Momentu.Widgets.TextView (Underline(..))
import qualified GUI.Momentu.Widgets.TextView as TextView
import           Lamdu.Config.Theme (Theme)
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Config.Theme.TextColors as TextColors
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM

import           Lamdu.Prelude

withUnderline ::
    (MonadReader env m, TextView.HasStyle env) => Theme -> m a -> m a
withUnderline theme =
    Underline
    { _underlineColor = TextColors.lightLambdaUnderlineColor (Theme.textColors theme)
    , _underlineWidth = Theme.wideUnderlineWidth theme
    } & ExprGuiM.withLocalUnderline
