{-# LANGUAGE TypeFamilies, FlexibleContexts, TupleSections #-}
module Lamdu.GUI.ExpressionGui.Annotation
    ( annotationSpacer
    , NeighborVals(..)
    , EvalAnnotationOptions(..), maybeAddAnnotationWith, maybeAddValAnnotationWith
    , WideAnnotationBehavior(..), wideAnnotationBehaviorFromSelected
    , evaluationResult
    , addAnnotationBackground -- used for open holes
    , maybeAddAnnotationPl
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Data.CurAndPrev (CurAndPrev(..), CurPrevTag(..), curPrevTag, fallbackToPrev)
import           Data.Vector.Vector2 (Vector2(..))
import           GUI.Momentu.Align (WithTextPos(..))
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Draw as Draw
import           GUI.Momentu.Element (Element)
import qualified GUI.Momentu.Element as Element
import           GUI.Momentu.Glue ((/-/))
import           GUI.Momentu.State (Gui)
import qualified GUI.Momentu.State as GuiState
import           GUI.Momentu.View (View)
import qualified GUI.Momentu.View as View
import           GUI.Momentu.Widget (Widget)
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified GUI.Momentu.Widgets.TextView as TextView
import           Lamdu.Config.Theme (HasTheme(..))
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.Config.Theme.ValAnnotation (ValAnnotation)
import qualified Lamdu.Config.Theme.ValAnnotation as ValAnnotation
import qualified Lamdu.GUI.EvalView as EvalView
import qualified Lamdu.GUI.ExpressionGui.Payload as ExprGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.GUI.TypeView as TypeView
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

addAnnotationBackgroundH ::
    (MonadReader env m, HasTheme env, Element a, Element.HasAnimIdPrefix env) =>
    Lens.ALens' ValAnnotation Draw.Color -> m (a -> a)
addAnnotationBackgroundH color =
    do
        t <- Lens.view theme
        bgAnimId <- Element.subAnimId ["annotation background"]
        Draw.backgroundColor bgAnimId (t ^# Theme.valAnnotation . color) & pure

addAnnotationBackground ::
    (MonadReader env m, HasTheme env, Element a, Element.HasAnimIdPrefix env) =>
    m (a -> a)
addAnnotationBackground = addAnnotationBackgroundH ValAnnotation.valAnnotationBGColor

addAnnotationHoverBackground ::
    (MonadReader env m, HasTheme env, Element a, Element.HasAnimIdPrefix env) => m (a -> a)
addAnnotationHoverBackground = addAnnotationBackgroundH ValAnnotation.valAnnotationHoverBGColor

data WideAnnotationBehavior
    = ShrinkWideAnnotation
    | HoverWideAnnotation
    | KeepWideTypeAnnotation

wideAnnotationBehaviorFromSelected :: Bool -> WideAnnotationBehavior
wideAnnotationBehaviorFromSelected False = ShrinkWideAnnotation
wideAnnotationBehaviorFromSelected True = HoverWideAnnotation

-- NOTE: Also adds the background color, because it differs based on
-- whether we're hovering
applyWideAnnotationBehavior ::
    (MonadReader env m, HasTheme env, Element.HasAnimIdPrefix env) =>
    WideAnnotationBehavior ->
    m (Vector2 Widget.R -> View -> View)
applyWideAnnotationBehavior KeepWideTypeAnnotation =
    addAnnotationBackground <&> const
applyWideAnnotationBehavior ShrinkWideAnnotation =
    addAnnotationBackground
    <&>
    \addBg shrinkRatio layout ->
    Element.scale shrinkRatio layout & addBg
applyWideAnnotationBehavior HoverWideAnnotation =
    do
        shrinker <- applyWideAnnotationBehavior ShrinkWideAnnotation
        addBg <- addAnnotationHoverBackground
        pure $
            \shrinkRatio layout ->
                -- TODO: This is a buggy hover that ignores
                -- Surrounding (and exits screen).
                shrinker shrinkRatio layout
                & Element.setLayers . Element.layers .~ addBg layout ^. View.vAnimLayers . Element.layers
                & Element.hoverLayers

processAnnotationGui ::
    ( MonadReader env m, HasTheme env, Spacer.HasStdSpacing env
    , Element.HasAnimIdPrefix env
    ) =>
    WideAnnotationBehavior ->
    m (Widget.R -> View -> View)
processAnnotationGui wideAnnotationBehavior =
    f
    <$> Lens.view (theme . Theme.valAnnotation)
    <*> addAnnotationBackground
    <*> Spacer.getSpaceSize
    <*> applyWideAnnotationBehavior wideAnnotationBehavior
    where
        f th addBg stdSpacing applyWide minWidth annotation
            | annotationWidth > minWidth + max shrinkAtLeast expansionLimit
            || heightShrinkRatio < 1 =
                applyWide shrinkRatio annotation
            | otherwise =
                maybeTooNarrow annotation & addBg
            where
                annotationWidth = annotation ^. Element.width
                expansionLimit = th ^. ValAnnotation.valAnnotationWidthExpansionLimit
                maxWidth = minWidth + expansionLimit
                shrinkAtLeast = th ^. ValAnnotation.valAnnotationShrinkAtLeast
                heightShrinkRatio =
                    th ^. ValAnnotation.valAnnotationMaxHeight * stdSpacing ^. _2
                    / annotation ^. Element.height
                shrinkRatio =
                    annotationWidth - shrinkAtLeast & min maxWidth & max minWidth
                    & (/ annotationWidth) & min heightShrinkRatio & pure
                maybeTooNarrow
                    | minWidth > annotationWidth = Element.pad (Vector2 ((minWidth - annotationWidth) / 2) 0)
                    | otherwise = id

data EvalResDisplay name = EvalResDisplay
    { erdSource :: CurPrevTag
    , erdVal :: Sugar.ResVal name
    }

makeEvaluationResultView ::
    (Monad i, Monad o) =>
    EvalResDisplay (Name f) ->
    ExprGuiM i o (WithTextPos View)
makeEvaluationResultView res =
    do
        th <- Lens.view theme
        EvalView.make (erdVal res)
            <&>
            case erdSource res of
            Current -> id
            Prev -> Element.tint (th ^. Theme.eval . Theme.staleResultTint)

data NeighborVals a = NeighborVals
    { prevNeighbor :: a
    , nextNeighbor :: a
    } deriving (Functor, Foldable, Traversable)

makeEvalView ::
    (Monad i, Monad o) =>
    Maybe (NeighborVals (Maybe (EvalResDisplay (Name f)))) ->
    EvalResDisplay (Name g) -> ExprGuiM i o (WithTextPos View)
makeEvalView mNeighbours evalRes =
    do
        evalTheme <- Lens.view (theme . Theme.eval)
        let neighbourView n =
                Lens._Just makeEvaluationResultViewBG n
                <&> Lens.mapped %~ Element.scale (evalTheme ^. Theme.neighborsScaleFactor)
                <&> Lens.mapped %~ Element.pad (evalTheme ^. Theme.neighborsPadding)
                <&> fromMaybe Element.empty
        (prev, next) <-
            case mNeighbours of
            Nothing -> pure (Element.empty, Element.empty)
            Just (NeighborVals mPrev mNext) ->
                (,)
                <$> neighbourView mPrev
                <*> neighbourView mNext
        evalView <- makeEvaluationResultView evalRes
        let prevPos = Vector2 0 0.5 * evalView ^. Element.size - prev ^. Element.size
        let nextPos = Vector2 1 0.5 * evalView ^. Element.size
        evalView
            & Element.setLayers <>~ Element.translateLayers prevPos (prev ^. View.vAnimLayers)
            & Element.setLayers <>~ Element.translateLayers nextPos (next ^. View.vAnimLayers)
            & pure
    where
        evalAnimId erd =
            erdVal erd ^. Sugar.resPayload & WidgetIds.fromEntityId & Widget.toAnimId
        makeEvaluationResultViewBG res =
            ( addAnnotationBackground
            & Reader.local (Element.animIdPrefix .~ evalAnimId res)
            ) <*> makeEvaluationResultView res
            <&> (^. Align.tValue)

annotationSpacer ::
    (MonadReader env m, HasTheme env, TextView.HasStyle env) => m View
annotationSpacer =
    Lens.view (Theme.theme . Theme.valAnnotation . ValAnnotation.valAnnotationSpacing)
    >>= Spacer.vspaceLines

addAnnotationH ::
    ( Functor f, MonadReader env m, HasTheme env
    , Spacer.HasStdSpacing env, Element.HasAnimIdPrefix env
    ) =>
    m (WithTextPos View) ->
    WideAnnotationBehavior ->
    m
    ((Widget.R -> Widget.R) ->
     Gui Widget f ->
     Gui Widget f)
addAnnotationH f wideBehavior =
    do
        vspace <- annotationSpacer
        annotationLayout <- f <&> (^. Align.tValue)
        processAnn <- processAnnotationGui wideBehavior
        let annotation minWidth w =
                processAnn (w ^. Element.width) annotationLayout
                & Element.width %~ max (minWidth (w ^. Element.width))
        let onAlignedWidget minWidth w = w /-/ vspace /-/ annotation minWidth w
        pure $ \minWidth -> onAlignedWidget minWidth

addInferredType ::
    ( Functor f, MonadReader env m, Spacer.HasStdSpacing env, HasTheme env
    , Element.HasAnimIdPrefix env
    ) =>
    Sugar.Type (Name g) -> WideAnnotationBehavior ->
    m (Gui Widget f -> Gui Widget f)
addInferredType typ wideBehavior =
    addAnnotationH (TypeView.make typ) wideBehavior ?? const 0

addEvaluationResult ::
    (Monad i, Monad o, Functor f) =>
    Maybe (NeighborVals (Maybe (EvalResDisplay (Name f)))) ->
    EvalResDisplay (Name g) -> WideAnnotationBehavior ->
    ExprGuiM i o
    ((Widget.R -> Widget.R) ->
     Gui Widget f ->
     Gui Widget f)
addEvaluationResult mNeigh resDisp wideBehavior =
    case erdVal resDisp ^. Sugar.resBody of
    Sugar.RRecord (Sugar.ResRecord []) ->
        Styled.addBgColor Theme.evaluatedPathBGColor <&> const
    Sugar.RFunc _ -> pure (flip const)
    _ ->
        case wideBehavior of
        KeepWideTypeAnnotation -> ShrinkWideAnnotation
        _ -> wideBehavior
        & addAnnotationH (makeEvalView mNeigh resDisp)

maybeAddAnnotationPl ::
    (Monad i, Monad o) =>
    Sugar.Payload (Name o) i o1 ExprGui.Payload ->
    ExprGuiM i o (Gui Widget o -> Gui Widget o)
maybeAddAnnotationPl pl =
    do
        wideAnnotationBehavior <-
            if pl ^. Sugar.plNeverShrinkAnnotation
            then pure KeepWideTypeAnnotation
            else isExprSelected <&> wideAnnotationBehaviorFromSelected
        maybeAddAnnotation wideAnnotationBehavior
            (pl ^. Sugar.plAnnotation)
            & Reader.local (Element.animIdPrefix .~ animId)
    where
        myId = WidgetIds.fromExprPayload pl
        isExprSelected =
            do
                isOnExpr <- GuiState.isSubCursor ?? myId
                isOnDotter <- GuiState.isSubCursor ?? WidgetIds.dotterId myId
                pure (isOnExpr && not isOnDotter)
        animId = WidgetIds.fromExprPayload pl & Widget.toAnimId

evaluationResult ::
    Monad i =>
    Sugar.Payload name i o ExprGui.Payload ->
    ExprGuiM i o (Maybe (Sugar.ResVal name))
evaluationResult pl =
    do
        scopeId <- ExprGuiM.readMScopeId
        case pl ^? Sugar.plAnnotation . Sugar._AnnotationVal . Sugar.annotationVal of
            Nothing -> pure Nothing
            Just x -> valOfScope x scopeId & ExprGuiM.im <&> Lens._Just %~ erdVal

data EvalAnnotationOptions
    = NormalEvalAnnotation
    | WithNeighbouringEvalAnnotations (NeighborVals (Maybe Sugar.BinderParamScopeId))

getAnnotationMode ::
    Monad i =>
    EvalAnnotationOptions -> Sugar.EvaluationScopes name i ->
    ExprGuiM i o (Maybe (EvalResDisplay name, Maybe (NeighborVals (Maybe (EvalResDisplay name)))))
getAnnotationMode opt annotation =
    do
        neighbourVals <-
            case opt of
            NormalEvalAnnotation -> pure Nothing
            WithNeighbouringEvalAnnotations neighbors ->
                -- neighbors <&> (>>= valOfScopePreferCur annotation . (^. Sugar.bParamScopeId))
                -- & Just
                neighbors & traverse . Lens._Just %%~
                    ExprGuiM.im . valOfScopePreferCur annotation . (^. Sugar.bParamScopeId)
                <&> traverse %~ join
                <&> Just
        ExprGuiM.readMScopeId
            >>= ExprGuiM.im . valOfScope annotation
            <&> Lens.mapped %~ (, neighbourVals)

maybeAddAnnotationWith ::
    (Monad i, Monad o) =>
    EvalAnnotationOptions -> WideAnnotationBehavior ->
    Sugar.Annotation (Name o) i ->
    ExprGuiM i o (Gui Widget o -> Gui Widget o)
maybeAddAnnotationWith opt wideAnnotationBehavior annotation =
    case annotation of
    Sugar.AnnotationNone -> pure id
    Sugar.AnnotationType typ -> addInferredType typ wideAnnotationBehavior
    Sugar.AnnotationVal ann -> maybeAddValAnnotationWith opt wideAnnotationBehavior ann

maybeAddValAnnotationWith ::
    (Monad i, Monad o) =>
    EvalAnnotationOptions -> WideAnnotationBehavior ->
    Sugar.ValAnnotation (Name o) i ->
    ExprGuiM i o (Gui Widget o -> Gui Widget o)
maybeAddValAnnotationWith opt wideAnnotationBehavior ann =
    getAnnotationMode opt (ann ^. Sugar.annotationVal)
    >>=
    \case
    Nothing -> maybe (pure id) (addInferredType ?? wideAnnotationBehavior) (ann ^. Sugar.annotationType)
    Just (scopeAndVal, mNeighborVals) ->
        do
            typeView <-
                case ann ^. Sugar.annotationType of
                Just typ -> TypeView.make typ <&> (^. Align.tValue)
                Nothing -> pure Element.empty
            process <- processAnnotationGui wideAnnotationBehavior
            addEvaluationResult mNeighborVals scopeAndVal wideAnnotationBehavior
                <&> \add -> add $ \width -> process width typeView ^. Element.width

maybeAddAnnotation ::
    (Monad i, Monad o) =>
    WideAnnotationBehavior -> Sugar.Annotation (Name o) i ->
    ExprGuiM i o (Gui Widget o -> Gui Widget o)
maybeAddAnnotation = maybeAddAnnotationWith NormalEvalAnnotation

valOfScope ::
    Applicative i =>
    Sugar.EvaluationScopes name i -> CurAndPrev (Maybe Sugar.ScopeId) ->
    i (Maybe (EvalResDisplay name))
valOfScope annotation mScopeIds =
    go
    <$> curPrevTag
    <*> annotation
    <*> mScopeIds
    & fallbackToPrev
    & sequenceA
    where
        go _ _ Nothing = Nothing
        go tag ann (Just scopeId) =
            ann ^? Lens._Just . Lens.ix scopeId <&> Lens.mapped %~ EvalResDisplay tag

valOfScopePreferCur ::
    Applicative i =>
    Sugar.EvaluationScopes name i -> Sugar.ScopeId ->
    i (Maybe (EvalResDisplay name))
valOfScopePreferCur annotation = valOfScope annotation . pure . Just
