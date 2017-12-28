{-# LANGUAGE NoImplicitPrelude, GeneralizedNewtypeDeriving, TemplateHaskell, OverloadedStrings, MultiParamTypeClasses, FlexibleInstances, TypeFamilies #-}
module Lamdu.GUI.ExpressionGui.Monad
    ( ExprGuiM
    , StoredEntityIds(..)
    , withLocalUnderline
    , withLocalSearchStringRemainer
    --
    , makeSubexpression
    , advanceDepth, resetDepth
    --
    , readCodeAnchors, mkPrejumpPosSaver
    --
    , readMScopeId, withLocalMScopeId
    , isExprSelected
    --
    , run
    ) where

import           Control.Applicative (liftA2)
import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Control.Monad.Trans.FastRWS (RWST, runRWST)
import qualified Control.Monad.Trans.FastRWS as RWS
import           Control.Monad.Transaction (MonadTransaction(..))
import           Control.Monad.Writer (MonadWriter)
import           Data.CurAndPrev (CurAndPrev)
import           Data.Store.Transaction (Transaction)
import           Data.Vector.Vector2 (Vector2)
import           GUI.Momentu.Align (WithTextPos)
import           GUI.Momentu.Animation.Id (AnimId)
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.Hover as Hover
import           GUI.Momentu.PreEvent (PreEvents, PreEvent(..), HasPreEvents(..))
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Responsive.Expression as ResponsiveExpr
import           GUI.Momentu.State (GUIState(..))
import qualified GUI.Momentu.State as GuiState
import           GUI.Momentu.View (View)
import           GUI.Momentu.Widget.Id (toAnimId)
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified GUI.Momentu.Widgets.TextEdit as TextEdit
import qualified GUI.Momentu.Widgets.TextView as TextView
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import           Lamdu.Config.Theme (Theme, HasTheme)
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Ops as DataOps
import           Lamdu.Eval.Results (ScopeId, topLevelScopeId)
import           Lamdu.GUI.CodeEdit.Settings (Settings, HasSettings(..))
import           Lamdu.GUI.ExpressionGui (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui as ExprGui
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Style (Style, HasStyle(..))
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

type T = Transaction

newtype StoredEntityIds = StoredEntityIds [Sugar.EntityId]
    deriving (Monoid)

data Askable m = Askable
    { _aState :: GUIState
    , _aTextEditStyle :: TextEdit.Style
    , _aStdSpacing :: Vector2 Double
    , _aAnimIdPrefix :: AnimId
    , _aSettings :: Settings
    , _aConfig :: Config
    , _aTheme :: Theme
    , _aMakeSubexpression :: ExprGui.SugarExpr m -> ExprGuiM m (ExpressionGui m)
    , _aCodeAnchors :: Anchors.CodeAnchors m
    , _aDepthLeft :: Int
    , _aMScopeId :: CurAndPrev (Maybe ScopeId)
    , _aStyle :: Style
    , -- Used for expressions in hole results
      _aSearchStringRemainder :: Text
    }
newtype ExprGuiM m a = ExprGuiM
    { _exprGuiM :: RWST (Askable m) (PreEvents (T m ())) () (T m) a
    } deriving (Functor, Applicative, Monad,
                MonadReader (Askable m), MonadWriter (PreEvents (T m ())))

instance (Monad m, Monoid a) => Monoid (ExprGuiM m a) where
    mempty = pure mempty
    mappend = liftA2 mappend

Lens.makeLenses ''Askable
Lens.makeLenses ''ExprGuiM

instance Monad m => MonadTransaction m (ExprGuiM m) where transaction = ExprGuiM . lift

instance GuiState.HasCursor (Askable m)
instance GuiState.HasState (Askable m) where state = aState
instance TextView.HasStyle (Askable m) where style = aTextEditStyle . TextView.style
instance TextEdit.HasStyle (Askable m) where style = aTextEditStyle
instance Spacer.HasStdSpacing (Askable m) where stdSpacing = aStdSpacing
instance Element.HasAnimIdPrefix (Askable m) where animIdPrefix = aAnimIdPrefix
instance Config.HasConfig (Askable m) where config = aConfig
instance HasTheme (Askable m) where theme = aTheme
instance ResponsiveExpr.HasStyle (Askable m) where style = aTheme . ResponsiveExpr.style
instance Menu.HasStyle (Askable m) where style = aTheme . Menu.style
instance Hover.HasStyle (Askable m) where style = aTheme . Hover.style
instance HasStyle (Askable m) where style = aStyle
instance HasSettings (Askable m) where settings = aSettings

withLocalSearchStringRemainer :: Monad m => Text -> ExprGuiM m a -> ExprGuiM m a
withLocalSearchStringRemainer = Reader.local . (aSearchStringRemainder .~)

withLocalUnderline ::
    (MonadReader env m, TextView.HasStyle env) => TextView.Underline -> m a -> m a
withLocalUnderline underline = Reader.local (TextView.underline ?~ underline)

readCodeAnchors :: Monad m => ExprGuiM m (Anchors.CodeAnchors m)
readCodeAnchors = Lens.view aCodeAnchors

mkPrejumpPosSaver :: Monad m => ExprGuiM m (T m ())
mkPrejumpPosSaver =
    DataOps.savePreJumpPosition <$> readCodeAnchors <*> Lens.view GuiState.cursor

makeSubexpression :: Monad m => ExprGui.SugarExpr m -> ExprGuiM m (ExpressionGui m)
makeSubexpression expr =
    do
        maker <- Lens.view aMakeSubexpression & ExprGuiM
        maker expr
    & advanceDepth (return . Responsive.fromTextView) animId
    where
        animId = expr ^. Sugar.rPayload & WidgetIds.fromExprPayload & toAnimId

resetDepth :: Int -> ExprGuiM m r -> ExprGuiM m r
resetDepth depth = exprGuiM %~ RWS.local (aDepthLeft .~ depth)

advanceDepth ::
    Monad m => (WithTextPos View -> ExprGuiM m r) ->
    AnimId -> ExprGuiM m r -> ExprGuiM m r
advanceDepth f animId action =
    do
        depth <- Lens.view aDepthLeft
        if depth <= 0
            then mkErrorWidget >>= f
            else action & exprGuiM %~ RWS.local (aDepthLeft -~ 1)
    where
        mkErrorWidget = TextView.make ?? "..." ?? animId

run ::
    ( MonadTransaction m n, MonadReader env n
    , GuiState.HasState env, Spacer.HasStdSpacing env
    , Config.HasConfig env, HasTheme env
    , HasSettings env, HasStyle env
    ) =>
    (ExprGui.SugarExpr m -> ExprGuiM m (ExpressionGui m)) ->
    Anchors.CodeAnchors m ->
    ExprGuiM m a ->
    n a
run makeSubexpr theCodeAnchors (ExprGuiM action) =
    do
        theSettings <- Lens.view settings
        theStyle <- Lens.view style
        theState <- Lens.view GuiState.state
        theTextEditStyle <- Lens.view TextEdit.style
        theStdSpacing <- Lens.view Spacer.stdSpacing
        theConfig <- Lens.view Config.config
        theTheme <- Lens.view Theme.theme
        runRWST action
            Askable
            { _aState = theState
            , _aTextEditStyle = theTextEditStyle
            , _aStdSpacing = theStdSpacing
            , _aAnimIdPrefix = ["outermost"]
            , _aConfig = theConfig
            , _aTheme = theTheme
            , _aSettings = theSettings
            , _aMakeSubexpression = makeSubexpr
            , _aCodeAnchors = theCodeAnchors
            , _aDepthLeft = Config.maxExprDepth theConfig
            , _aMScopeId = Just topLevelScopeId & pure
            , _aStyle = theStyle
            , _aSearchStringRemainder = ""
            }
            ()
            <&> (\(x, (), _output) -> x)
            & transaction

instance Monad m => HasPreEvents (ExprGuiM m) where
    type Event (ExprGuiM m) = T m ()
    listenPreEvents action =
        do
            (result, preEvents) <- action & exprGuiM %~ RWS.listen
            remainderText <- Lens.view aSearchStringRemainder
            let remainder =
                    PreEvent
                    { pDesc = ""
                    , pAction = return ()
                    , pTextRemainder = remainderText
                    }
            pure (result, preEvents ++ [remainder])

readMScopeId :: Monad m => ExprGuiM m (CurAndPrev (Maybe ScopeId))
readMScopeId = Lens.view aMScopeId

withLocalMScopeId :: CurAndPrev (Maybe ScopeId) -> ExprGuiM m a -> ExprGuiM m a
withLocalMScopeId mScopeId = exprGuiM %~ RWS.local (aMScopeId .~ mScopeId)

isExprSelected ::
    (MonadReader env m, GuiState.HasCursor env) =>
    Sugar.Payload f a -> m Bool
isExprSelected pl = GuiState.isSubCursor ?? WidgetIds.fromExprPayload pl
