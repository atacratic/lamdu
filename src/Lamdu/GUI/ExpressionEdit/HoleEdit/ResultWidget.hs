
module Lamdu.GUI.ExpressionEdit.HoleEdit.ResultWidget
    ( make
    ) where

import qualified Control.Lens as Lens
import           GUI.Momentu (Widget, WithTextPos(..))
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Element as Element
import           GUI.Momentu.EventMap (EventMap)
import qualified GUI.Momentu.EventMap as E
import qualified GUI.Momentu.MetaKey as MetaKey
import           GUI.Momentu.Rect (Rect(..))
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Grid as Grid
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Menu.Search as SearchMenu
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import           Lamdu.Config (HasConfig(..))
import qualified Lamdu.Config as Config
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.GUI.ExpressionEdit.HoleEdit.ValTerms (getSearchStringRemainder)
import qualified Lamdu.GUI.ExpressionGui as ExprGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name(..))
import qualified Lamdu.Sugar.Lens as SugarLens
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

setFocalAreaToFullSize :: WithTextPos (Widget a) -> WithTextPos (Widget a)
setFocalAreaToFullSize =
    Align.tValue . Widget.sizedState <. Widget._StateFocused . Lens.mapped . Widget.fFocalAreas .@~
    (:[]) . Rect 0

-- | Remove unwanted event handlers from a hole result
removeUnwanted :: (MonadReader env m, HasConfig env) => m (EventMap a -> EventMap a)
removeUnwanted =
    Lens.view config
    <&>
    \c ->
    concat
    [ Config.delKeys c
    , c ^. Config.enterSubexpressionKeys
    , c ^. Config.leaveSubexpressionKeys
    , c ^. Config.letAddItemKeys
    , Grid.stdKeys ^.. Lens.folded
    ]
    <&> MetaKey.toModKey
    <&> E.KeyEvent MetaKey.KeyState'Pressed
    & E.deleteKeys

applyResultLayout :: Responsive a -> WithTextPos (Widget a)
applyResultLayout = (^. Responsive.rWide)

makeWidget ::
    (Monad i, Functor o) =>
    Widget.Id ->
    Sugar.Expression (Name o) i o ExprGui.Payload ->
    ExprGuiM i o (WithTextPos (Widget (o GuiState.Update)))
makeWidget resultId holeResultConverted =
    do
        remUnwanted <- removeUnwanted
        theme <- Lens.view (Theme.theme . Theme.hole)
        stdSpacing <- Spacer.getSpaceSize
        let padding = theme ^. Theme.holeResultPadding & (* stdSpacing)
        ExprGuiM.makeSubexpression holeResultConverted
            <&> Widget.enterResultCursor .~ resultId
            <&> Widget.widget . Widget.eventMapMaker . Lens.mapped %~ remUnwanted
            <&> applyResultLayout
            <&> setFocalAreaToFullSize
            <&> Element.pad padding
            & ExprGuiM.withLocalIsHoleResult

make ::
    (Monad i, Functor o) =>
    Maybe Widget.Id ->
    SearchMenu.ResultsContext ->
    Widget.Id ->
    Sugar.HoleResult o (Sugar.Expression (Name o) i o ExprGui.Payload) ->
    ExprGuiM i o (Menu.RenderedOption o)
make mNextEntry ctx resultId holeResult =
    makeWidget resultId holeResultConverted
    & GuiState.assignCursor resultId (pickResult ^. Menu.pickDest)
    <&>
    \widget ->
    Menu.RenderedOption
    { Menu._rPick =
        Widget.PreEvent
        { Widget._pDesc = "Pick"
        , Widget._pAction = pickResult <$ holeResult ^. Sugar.holeResultPick
        , Widget._pTextRemainder = getSearchStringRemainder ctx holeResultConverted
        }
    , Menu._rWidget = widget
    }
    where
        holeResultId =
            holeResultConverted ^. Sugar.annotation . Sugar.plEntityId
            & WidgetIds.fromEntityId
        mFirstHoleInside =
            holeResult ^?
            Sugar.holeResultConverted . SugarLens.unfinishedExprPayloads . Sugar.plEntityId
            <&> WidgetIds.fromEntityId
        pickResult =
            case mFirstHoleInside of
            Nothing ->
                Menu.PickResult
                { Menu._pickDest = holeResultId
                , Menu._pickNextEntryPoint = fromMaybe holeResultId mNextEntry
                }
            Just innerEntryPoint ->
                Menu.PickResult
                { Menu._pickDest = innerEntryPoint
                , Menu._pickNextEntryPoint = innerEntryPoint
                }
        holeResultConverted = holeResult ^. Sugar.holeResultConverted
