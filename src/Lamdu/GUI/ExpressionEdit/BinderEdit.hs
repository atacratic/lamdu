{-# LANGUAGE NamedFieldPuns, FlexibleContexts, NoMonomorphismRestriction #-}
module Lamdu.GUI.ExpressionEdit.BinderEdit
    ( make
    , makeBinderBodyEdit, makeBinderContentEdit
    , addLetEventMap
    , Parts(..), makeParts, makeFunctionParts
    ) where

import           Control.Applicative ((<|>), liftA2)
import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Data.CurAndPrev (CurAndPrev, current, fallbackToPrev)
import           Data.List.Extended (withPrevNext)
import qualified Data.Map as Map
import           Data.Property (Property)
import qualified Data.Property as Property
import           GUI.Momentu.Align (WithTextPos)
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Direction as Direction
import qualified GUI.Momentu.Draw as Draw
import qualified GUI.Momentu.Element as Element
import           GUI.Momentu.EventMap (EventMap)
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Glue ((/-/), (/|/))
import qualified GUI.Momentu.Glue as Glue
import           GUI.Momentu.MetaKey (MetaKey(..), noMods, toModKey)
import qualified GUI.Momentu.MetaKey as MetaKey
import           GUI.Momentu.Rect (Rect(Rect))
import qualified GUI.Momentu.Rect as Rect
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Responsive.Options as Options
import qualified GUI.Momentu.State as GuiState
import           GUI.Momentu.Widget (Widget)
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified GUI.Momentu.Widgets.TextView as TextView
import qualified Lamdu.Config as Config
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.Config.Theme.TextColors (TextColors)
import qualified Lamdu.Config.Theme.TextColors as TextColors
import qualified Lamdu.Data.Meta as Meta
import           Lamdu.GUI.CodeEdit.AnnotationMode (AnnotationMode(..))
import qualified Lamdu.GUI.ExpressionEdit.EventMap as ExprEventMap
import qualified Lamdu.GUI.ExpressionEdit.TagEdit as TagEdit
import           Lamdu.GUI.ExpressionGui (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui as ExprGui
import qualified Lamdu.GUI.ExpressionGui.Annotation as Annotation
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import           Lamdu.GUI.ExpressionGui.Wrap (parentDelegator)
import qualified Lamdu.GUI.ParamEdit as ParamEdit
import qualified Lamdu.GUI.PresentationModeEdit as PresentationModeEdit
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name(..))
import qualified Lamdu.Settings as Settings
import qualified Lamdu.Sugar.Lens as SugarLens
import           Lamdu.Sugar.NearestHoles (NearestHoles)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

makeBinderNameEdit ::
    (Monad i, Applicative o) =>
    Widget.Id -> Sugar.AddFirstParam (Name o) i o ->
    EventMap (o GuiState.Update) ->
    Sugar.Tag (Name o) i o -> Lens.ALens' TextColors Draw.Color ->
    ExprGuiM i o (WithTextPos (Widget (o GuiState.Update)))
makeBinderNameEdit binderId addFirstParam rhsJumperEquals tag color =
    do
        addFirstParamEventMap <- ParamEdit.eventMapAddFirstParam binderId addFirstParam
        let eventMap = rhsJumperEquals <> addFirstParamEventMap
        TagEdit.makeBinderTagEdit color tag
            <&> Align.tValue %~ Widget.weakerEvents eventMap

data Parts o = Parts
    { pMParamsEdit :: Maybe (ExpressionGui o)
    , pMScopesEdit :: Maybe (Widget (o GuiState.Update))
    , pBodyEdit :: ExpressionGui o
    , pEventMap :: EventMap (o GuiState.Update)
    }

data ScopeCursor = ScopeCursor
    { sBinderScope :: Sugar.BinderParamScopeId
    , sMPrevParamScope :: Maybe Sugar.BinderParamScopeId
    , sMNextParamScope :: Maybe Sugar.BinderParamScopeId
    }

trivialScopeCursor :: Sugar.BinderParamScopeId -> ScopeCursor
trivialScopeCursor x = ScopeCursor x Nothing Nothing

scopeCursor :: Maybe Sugar.BinderParamScopeId -> [Sugar.BinderParamScopeId] -> Maybe ScopeCursor
scopeCursor mChosenScope scopes =
    do
        chosenScope <- mChosenScope
        (prevs, it:nexts) <- break (== chosenScope) scopes & Just
        Just ScopeCursor
            { sBinderScope = it
            , sMPrevParamScope = reverse prevs ^? Lens.traversed
            , sMNextParamScope = nexts ^? Lens.traversed
            }
    <|> (scopes ^? Lens.traversed <&> def)
    where
        def binderScope =
            ScopeCursor
            { sBinderScope = binderScope
            , sMPrevParamScope = Nothing
            , sMNextParamScope = scopes ^? Lens.ix 1
            }

lookupMKey :: Ord k => Maybe k -> Map k a -> Maybe a
lookupMKey k m = k >>= (`Map.lookup` m)

readFunctionChosenScope ::
    Functor i => Sugar.Function name i o expr -> i (Maybe Sugar.BinderParamScopeId)
readFunctionChosenScope func = func ^. Sugar.fChosenScopeProp <&> Property.value

mkChosenScopeCursor ::
    Monad i =>
    Sugar.Function (Name o) i o (Sugar.Payload name i o ExprGui.Payload) ->
    ExprGuiM i o (CurAndPrev (Maybe ScopeCursor))
mkChosenScopeCursor func =
    do
        mOuterScopeId <- ExprGuiM.readMScopeId
        case func ^. Sugar.fBodyScopes of
            Sugar.SameAsParentScope ->
                mOuterScopeId <&> fmap (trivialScopeCursor . Sugar.BinderParamScopeId) & pure
            Sugar.BinderBodyScope assignmentBodyScope ->
                readFunctionChosenScope func & ExprGuiM.im
                <&> \mChosenScope ->
                liftA2 lookupMKey mOuterScopeId assignmentBodyScope
                <&> (>>= scopeCursor mChosenScope)

makeScopeEventMap ::
    Functor o =>
    [MetaKey] -> [MetaKey] -> ScopeCursor -> (Sugar.BinderParamScopeId -> o ()) ->
    EventMap (o GuiState.Update)
makeScopeEventMap prevKey nextKey cursor setter =
    do
        (key, doc, scope) <-
            (sMPrevParamScope cursor ^.. Lens._Just <&> (,,) prevKey prevDoc) ++
            (sMNextParamScope cursor ^.. Lens._Just <&> (,,) nextKey nextDoc)
        [setter scope & E.keysEventMap key doc]
    & mconcat
    where
        prevDoc = E.Doc ["Evaluation", "Scope", "Previous"]
        nextDoc = E.Doc ["Evaluation", "Scope", "Next"]

blockEventMap :: Applicative m => EventMap (m GuiState.Update)
blockEventMap =
    pure mempty
    & E.keyPresses (dirKeys <&> toModKey)
    (E.Doc ["Navigation", "Move", "(blocked)"])
    where
        dirKeys = [MetaKey.Key'Left, MetaKey.Key'Right] <&> MetaKey noMods

makeScopeNavArrow ::
    ( MonadReader env m, Theme.HasTheme env, TextView.HasStyle env
    , Element.HasAnimIdPrefix env, Monoid a, Applicative o
    ) =>
    (w -> o a) -> Text -> Maybe w -> m (WithTextPos (Widget (o a)))
makeScopeNavArrow setScope arrowText mScopeId =
    do
        theme <- Lens.view Theme.theme
        TextView.makeLabel arrowText
            <&> Align.tValue %~ Widget.fromView
            <&> Align.tValue %~
                Widget.sizedState <. Widget._StateUnfocused . Widget.uMEnter
                .@~ mEnter
            & Reader.local
            ( TextView.color .~
                case mScopeId of
                Nothing -> theme ^. Theme.disabledColor
                Just _ -> theme ^. Theme.textColors . TextColors.grammarColor
            )
    where
        mEnter size =
            mScopeId
            <&> setScope
            <&> validate
            where
                r = Rect 0 size
                res = Widget.EnterResult r 0
                validate action (Direction.Point point)
                    | point `Rect.isWithin` r = res action
                validate _ _ = res (pure mempty)

makeScopeNavEdit ::
    (Monad i, Applicative o) =>
    Sugar.Function name i o expr -> Widget.Id -> ScopeCursor ->
    ExprGuiM i o
    ( EventMap (o GuiState.Update)
    , Maybe (Widget (o GuiState.Update))
    )
makeScopeNavEdit func myId curCursor =
    do
        evalConfig <- Lens.view (Config.config . Config.eval)
        chosenScopeProp <- func ^. Sugar.fChosenScopeProp & ExprGuiM.im
        let setScope =
                (mempty <$) .
                Property.set chosenScopeProp . Just
        let mkScopeEventMap l r = makeScopeEventMap l r curCursor setScope
        Lens.view (Settings.settings . Settings.sAnnotationMode)
            >>= \case
            Evaluation ->
                (Widget.makeFocusableWidget ?? myId)
                <*> ( traverse (uncurry (makeScopeNavArrow setScope)) scopes
                        <&> Glue.hbox <&> (^. Align.tValue)
                    )
                <&> Widget.weakerEvents
                    (mkScopeEventMap leftKeys rightKeys <> blockEventMap)
                <&> Just
                <&> (,) (mkScopeEventMap
                         (evalConfig ^. Config.prevScopeKeys)
                         (evalConfig ^. Config.nextScopeKeys))
            _ -> pure (mempty, Nothing)
    where
        leftKeys = [MetaKey noMods MetaKey.Key'Left]
        rightKeys = [MetaKey noMods MetaKey.Key'Right]
        scopes :: [(Text, Maybe Sugar.BinderParamScopeId)]
        scopes =
            [ ("◀", sMPrevParamScope curCursor)
            , (" ", Nothing)
            , ("▶", sMNextParamScope curCursor)
            ]

data IsScopeNavFocused = ScopeNavIsFocused | ScopeNavNotFocused
    deriving (Eq, Ord)

makeMParamsEdit ::
    (Monad i, Monad o) =>
    CurAndPrev (Maybe ScopeCursor) -> IsScopeNavFocused ->
    Widget.Id -> Widget.Id ->
    NearestHoles -> Widget.Id ->
    Sugar.AddFirstParam (Name o) i o ->
    Maybe (Sugar.BinderParams (Name o) i o) ->
    ExprGuiM i o (Maybe (ExpressionGui o))
makeMParamsEdit mScopeCursor isScopeNavFocused delVarBackwardsId myId nearestHoles bodyId addFirstParam mParams =
    do
        isPrepend <- GuiState.isSubCursor ?? prependId
        prependParamEdits <-
            case addFirstParam of
            Sugar.PrependParam selection | isPrepend ->
                TagEdit.makeTagHoleEdit selection ParamEdit.mkParamPickResult prependId
                & Styled.withColor TextColors.parameterColor
                <&> Responsive.fromWithTextPos
                <&> (:[])
            _ -> pure []
        paramEdits <-
            case mParams of
            Nothing -> pure []
            Just params ->
                makeParamsEdit annotationMode nearestHoles
                delVarBackwardsId myId bodyId params
                & ExprGuiM.withLocalMScopeId
                    ( mScopeCursor
                        <&> Lens.traversed %~ (^. Sugar.bParamScopeId) . sBinderScope
                    )
        case prependParamEdits ++ paramEdits of
            [] -> pure Nothing
            edits ->
                frame
                <*> (Options.boxSpaced ?? Options.disambiguationNone ?? edits)
                <&> Just
    where
        prependId = TagEdit.addParamId myId
        frame =
            case mParams of
            Just (Sugar.Params (_:_:_)) -> Styled.addValFrame
            _ -> pure id
        mCurCursor =
            do
                ScopeNavIsFocused == isScopeNavFocused & guard
                mScopeCursor ^. current
        annotationMode =
            Annotation.NeighborVals
            (mCurCursor >>= sMPrevParamScope)
            (mCurCursor >>= sMNextParamScope)
            & Annotation.WithNeighbouringEvalAnnotations

binderContentNearestHoles ::
    Sugar.BinderContent name i o (Sugar.Payload name i o ExprGui.Payload) ->
    NearestHoles
binderContentNearestHoles body =
    body ^? SugarLens.binderContentExprs
    & fromMaybe (error "We have at least a body expression inside the binder")
    & ExprGui.nextHolesBefore

makeFunctionParts ::
    (Monad i, Monad o) =>
    ExprGui.FuncApplyLimit ->
    Sugar.Function (Name o) i o (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    Widget.Id -> Widget.Id ->
    ExprGuiM i o (Parts o)
makeFunctionParts funcApplyLimit func delVarBackwardsId myId =
    do
        mScopeCursor <- mkChosenScopeCursor func
        let binderScopeId = mScopeCursor <&> Lens.mapped %~ (^. Sugar.bParamScopeId) . sBinderScope
        (scopeEventMap, mScopeNavEdit) <-
            do
                guard (funcApplyLimit == ExprGui.UnlimitedFuncApply)
                scope <- fallbackToPrev mScopeCursor
                guard $
                    Lens.nullOf (Sugar.fParams . Sugar._NullParam) func ||
                    Lens.has (Lens.traversed . Lens._Just) [sMPrevParamScope scope, sMNextParamScope scope]
                Just scope
            & maybe (pure (mempty, Nothing)) (makeScopeNavEdit func scopesNavId)
        let isScopeNavFocused =
                case mScopeNavEdit of
                Just edit | Widget.isFocused edit -> ScopeNavIsFocused
                _ -> ScopeNavNotFocused
        do
            paramsEdit <-
                makeMParamsEdit mScopeCursor isScopeNavFocused delVarBackwardsId myId
                (binderContentNearestHoles bodyContent) bodyId (func ^. Sugar.fAddFirstParam) (Just (func ^. Sugar.fParams))
            rhs <- makeBinderBodyEdit (func ^. Sugar.fBody)
            Parts paramsEdit mScopeNavEdit rhs scopeEventMap & pure
            & case mScopeNavEdit of
              Nothing -> GuiState.assignCursorPrefix scopesNavId (const destId)
              Just _ -> id
            & ExprGuiM.withLocalMScopeId binderScopeId
    where
        destId =
            case func ^. Sugar.fParams of
            Sugar.NullParam{} -> bodyId
            Sugar.Params ps ->
                ps ^?! traverse . Sugar.fpInfo . Sugar.piTag . Sugar.tagInfo . Sugar.tagInstance & WidgetIds.fromEntityId
        scopesNavId = Widget.joinId myId ["scopesNav"]
        bodyId = bodyContent ^. SugarLens.binderContentEntityId & WidgetIds.fromEntityId
        bodyContent = func ^. Sugar.fBody . Sugar.bbContent

makePlainParts ::
    (Monad i, Monad o) =>
    Sugar.AssignPlain (Name o) i o
    (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    Widget.Id -> Widget.Id ->
    ExprGuiM i o (Parts o)
makePlainParts binder delVarBackwardsId myId =
    do
        mParamsEdit <-
            makeMParamsEdit (pure Nothing) ScopeNavNotFocused delVarBackwardsId myId
            (binderContentNearestHoles bodyContent) bodyId (binder ^. Sugar.apAddFirstParam) Nothing
        rhs <- makeBinderBodyEdit (binder ^. Sugar.apBody)
        Parts mParamsEdit Nothing rhs mempty & pure
    where
        bodyId = bodyContent ^. SugarLens.binderContentEntityId & WidgetIds.fromEntityId
        bodyContent = binder ^. Sugar.apBody . Sugar.bbContent

makeParts ::
    (Monad i, Monad o) =>
    ExprGui.FuncApplyLimit ->
    Sugar.Assignment (Name o) i o
    (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    Widget.Id -> Widget.Id ->
    ExprGuiM i o (Parts o)
makeParts funcApplyLimit binder =
    case binder ^. Sugar.aBody of
    Sugar.BodyFunction x -> makeFunctionParts funcApplyLimit (x ^. Sugar.afFunction)
    Sugar.BodyPlain x -> makePlainParts x

maybeAddNodeActions ::
    (MonadReader env m, GuiState.HasCursor env, Config.HasConfig env, Applicative o) =>
    Widget.Id -> NearestHoles -> Sugar.NodeActions name i o ->
    m (Responsive (o GuiState.Update) -> Responsive (o GuiState.Update))
maybeAddNodeActions partId nearestHoles nodeActions =
    do
        isSelected <- Lens.view GuiState.cursor <&> (== partId)
        if isSelected
            then
                ExprEventMap.addWith ExprEventMap.defaultOptions
                ExprEventMap.ExprInfo
                { ExprEventMap.exprInfoActions = nodeActions
                , ExprEventMap.exprInfoNearestHoles = nearestHoles
                , ExprEventMap.exprInfoIsHoleResult = False
                , ExprEventMap.exprInfoMinOpPrec = 0
                , ExprEventMap.exprInfoIsSelected = True
                }
            else
                pure id

make ::
    (Monad i, Monad o) =>
    Maybe (i (Property o Meta.PresentationMode)) ->
    EventMap (o GuiState.Update) ->
    Sugar.Tag (Name o) i o -> Lens.ALens' TextColors Draw.Color ->
    Sugar.Assignment (Name o) i o
    (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    Widget.Id ->
    ExprGuiM i o (ExpressionGui o)
make pMode defEventMap tag color binder myId =
    do
        Parts mParamsEdit mScopeEdit bodyEdit eventMap <-
            makeParts ExprGui.UnlimitedFuncApply binder myId myId
        rhsJumperEquals <- jumpToRHS bodyId
        mPresentationEdit <-
            case binder ^. Sugar.aBody of
            Sugar.BodyPlain{} -> pure Nothing
            Sugar.BodyFunction x ->
                pMode & sequenceA & ExprGuiM.im
                >>= traverse
                    (PresentationModeEdit.make presentationChoiceId (x ^. Sugar.afFunction . Sugar.fParams))
        jumpHolesEventMap <- ExprEventMap.jumpHolesEventMap nearestHoles
        defNameEdit <-
            makeBinderNameEdit myId (binder ^. SugarLens.assignmentAddFirstParam) rhsJumperEquals
            tag color
            <&> (/-/ fromMaybe Element.empty mPresentationEdit)
            <&> Responsive.fromWithTextPos
            <&> Widget.weakerEvents jumpHolesEventMap
        mParamEdit <-
            case mParamsEdit of
            Nothing -> pure Nothing
            Just paramsEdit ->
                Responsive.vboxSpaced
                ?? (paramsEdit : fmap Responsive.fromWidget mScopeEdit ^.. Lens._Just)
                <&> Widget.strongerEvents rhsJumperEquals
                <&> Just
        equals <- TextView.makeLabel "="
        addWholeBinderActions <-
            maybeAddNodeActions wholeBinderId nearestHoles (binder ^. Sugar.aNodeActions)
        hbox <- Options.boxSpaced ?? Options.disambiguationNone
        let layout =
                hbox
                [ defNameEdit :
                    (mParamEdit ^.. Lens._Just) ++
                    [Responsive.fromTextView equals]
                    & hbox
                , bodyEdit
                ]
        parentDelegator wholeBinderId ?? layout
            <&> Widget.weakerEvents (defEventMap <> eventMap)
            <&> addWholeBinderActions
    & Reader.local (Element.animIdPrefix .~ Widget.toAnimId myId)
    & case binder ^? Sugar.aBody . Sugar._BodyFunction . Sugar.afLamId of
        Nothing -> id
        Just lamId ->
            GuiState.assignCursorPrefix (WidgetIds.fromEntityId lamId) (const bodyId)
    & GuiState.assignCursor (WidgetIds.newDest myId) (WidgetIds.tagHoleId nameId)
    & GuiState.assignCursor myId nameId
    where
        wholeBinderId = Widget.joinId myId ["whole binder"]
        nameId = tag ^. Sugar.tagInfo . Sugar.tagInstance & WidgetIds.fromEntityId
        presentationChoiceId = Widget.joinId myId ["presentation"]
        body = binder ^. SugarLens.assignmentBody
        bodyId = body ^. Sugar.bbContent . SugarLens.binderContentEntityId & WidgetIds.fromEntityId
        nearestHoles = binderContentNearestHoles (body ^. Sugar.bbContent)

makeLetEdit ::
    (Monad i, Monad o) =>
    Sugar.Let (Name o) i o (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    ExprGuiM i o (ExpressionGui o)
makeLetEdit item =
    do
        config <- Lens.view Config.config
        theme <- Lens.view Theme.theme
        let eventMap =
                foldMap
                ( E.keysEventMapMovesCursor (config ^. Config.extractKeys)
                    (E.Doc ["Edit", "Let clause", "Extract to outer scope"])
                    . fmap ExprEventMap.extractCursor
                ) (item ^? Sugar.lValue . Sugar.aNodeActions . Sugar.extract)
                <>
                E.keysEventMapMovesCursor (Config.delKeys config)
                (E.Doc ["Edit", "Let clause", "Delete"])
                (bodyId <$ item ^. Sugar.lActions . Sugar.laDelete)
                <>
                foldMap
                ( E.keysEventMapMovesCursor (config ^. Config.inlineKeys)
                    (E.Doc ["Navigation", "Jump to first use"])
                    . pure . WidgetIds.fromEntityId
                ) (item ^? Sugar.lUsages . Lens.ix 0)
        letLabel <- Styled.grammarLabel "let"
        space <- Spacer.stdHSpace
        letEquation <-
            make Nothing mempty (item ^. Sugar.lName) TextColors.letColor binder letId
            <&> Widget.weakerEvents eventMap
            <&> Element.pad (theme ^. Theme.letItemPadding)
        letLabel /|/ space /|/ letEquation & pure
    & Reader.local (Element.animIdPrefix .~ Widget.toAnimId letId)
    where
        bodyId =
            item ^. Sugar.lBody . Sugar.bbContent . SugarLens.binderContentEntityId
            & WidgetIds.fromEntityId
        letId =
            item ^. Sugar.lEntityId & WidgetIds.fromEntityId
            & WidgetIds.letBinderId
        binder = item ^. Sugar.lValue

jumpToRHS ::
    (Monad i, Monad o) =>
    Widget.Id -> ExprGuiM i o (EventMap (o GuiState.Update))
jumpToRHS rhsId =
    ExprGuiM.mkPrejumpPosSaver
    <&> Lens.mapped .~ rhsId
    <&> E.keysEventMapMovesCursor [MetaKey noMods MetaKey.Key'Equal]
        (E.Doc ["Navigation", "Jump to Def Body"])

addLetEventMap ::
    (Monad i, Monad o) =>
    o Sugar.EntityId -> ExprGuiM i o (EventMap (o GuiState.Update))
addLetEventMap addLet =
    do
        config <- Lens.view Config.config
        savePos <- ExprGuiM.mkPrejumpPosSaver
        savePos >> addLet
            <&> WidgetIds.fromEntityId <&> WidgetIds.letBinderId
            & E.keysEventMapMovesCursor (config ^. Config.letAddItemKeys)
                (E.Doc ["Edit", "Let clause", "Add"])
            & pure

makeBinderBodyEdit ::
    (Monad i, Monad o) =>
    Sugar.BinderBody (Name o) i o
    (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    ExprGuiM i o (ExpressionGui o)
makeBinderBodyEdit (Sugar.BinderBody addOuterLet content) =
    do
        newLetEventMap <- addLetEventMap addOuterLet
        makeBinderContentEdit content <&> Widget.weakerEvents newLetEventMap

makeBinderContentEdit ::
    (Monad i, Monad o) =>
    Sugar.BinderContent (Name o) i o
    (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    ExprGuiM i o (ExpressionGui o)
makeBinderContentEdit (Sugar.BinderExpr assignmentBody) =
    ExprGuiM.makeSubexpression assignmentBody
makeBinderContentEdit content@(Sugar.BinderLet l) =
    do
        config <- Lens.view Config.config
        let moveToInnerEventMap =
                body
                ^? Sugar.bbContent . Sugar._BinderLet
                . Sugar.lActions . Sugar.laNodeActions . Sugar.extract
                & foldMap
                (E.keysEventMap (config ^. Config.moveLetInwardKeys)
                (E.Doc ["Edit", "Let clause", "Move inwards"]) . void)
        mAddNodeActions <-
            maybeAddNodeActions letEntityId (binderContentNearestHoles content)
            (l ^. Sugar.lActions . Sugar.laNodeActions)
        mOuterScopeId <- ExprGuiM.readMScopeId
        let letBodyScope = liftA2 lookupMKey mOuterScopeId (l ^. Sugar.lBodyScope)
        parentDelegator letEntityId
            <*>
            ( Responsive.vboxSpaced
                <*>
                sequence
                [ makeLetEdit l <&> Widget.weakerEvents moveToInnerEventMap
                , makeBinderBodyEdit body
                & ExprGuiM.withLocalMScopeId letBodyScope
                ]
            )
            <&> mAddNodeActions
    where
        letEntityId = l ^. Sugar.lEntityId & WidgetIds.fromEntityId
        body = l ^. Sugar.lBody

namedParamEditInfo ::
    Widget.Id -> Sugar.FuncParamActions (Name o) i o ->
    WithTextPos (Widget (o GuiState.Update)) ->
    ParamEdit.Info i o
namedParamEditInfo widgetId actions nameEdit =
    ParamEdit.Info
    { ParamEdit.iNameEdit = nameEdit
    , ParamEdit.iAddNext = actions ^. Sugar.fpAddNext & Just
    , ParamEdit.iMOrderBefore = actions ^. Sugar.fpMOrderBefore
    , ParamEdit.iMOrderAfter = actions ^. Sugar.fpMOrderAfter
    , ParamEdit.iDel = actions ^. Sugar.fpDelete
    , ParamEdit.iId = widgetId
    }

nullParamEditInfo ::
    Widget.Id -> WithTextPos (Widget (o GuiState.Update)) ->
    Sugar.NullParamActions o -> ParamEdit.Info i o
nullParamEditInfo widgetId nameEdit mActions =
    ParamEdit.Info
    { ParamEdit.iNameEdit = nameEdit
    , ParamEdit.iAddNext = Nothing
    , ParamEdit.iMOrderBefore = Nothing
    , ParamEdit.iMOrderAfter = Nothing
    , ParamEdit.iDel = mActions ^. Sugar.npDeleteLambda
    , ParamEdit.iId = widgetId
    }

makeParamsEdit ::
    (Monad i, Monad o) =>
    Annotation.EvalAnnotationOptions -> NearestHoles ->
    Widget.Id -> Widget.Id -> Widget.Id ->
    Sugar.BinderParams (Name o) i o ->
    ExprGuiM i o [ExpressionGui o]
makeParamsEdit annotationOpts nearestHoles delVarBackwardsId lhsId rhsId params =
    case params of
    Sugar.NullParam p ->
        do
            nullParamGui <-
                (Widget.makeFocusableView ?? nullParamId <&> (Align.tValue %~))
                <*> Styled.grammarLabel "|"
            fromParamList delVarBackwardsId rhsId
                [p & Sugar.fpInfo %~ nullParamEditInfo lhsId nullParamGui]
        where
            nullParamId = Widget.joinId lhsId ["param"]
    Sugar.Params ps ->
        ps
        & traverse . Sugar.fpInfo %%~ onFpInfo
        >>= fromParamList delVarBackwardsId rhsId
        where
            onFpInfo x =
                TagEdit.makeParamTag (x ^. Sugar.piTag)
                <&> namedParamEditInfo widgetId (x ^. Sugar.piActions)
                where
                    widgetId =
                        x ^. Sugar.piTag . Sugar.tagInfo . Sugar.tagInstance & WidgetIds.fromEntityId
    where
        fromParamList delDestFirst delDestLast paramList =
            do
                jumpHolesEventMap <- ExprEventMap.jumpHolesEventMap nearestHoles
                withPrevNext delDestFirst delDestLast
                    (ParamEdit.iId . (^. Sugar.fpInfo)) paramList
                    & traverse mkParam <&> concat
                    <&> traverse . Widget.widget . Widget.eventMapMaker . Lens.mapped <>~ jumpHolesEventMap
            where
                mkParam (prevId, nextId, param) = ParamEdit.make annotationOpts prevId nextId param
