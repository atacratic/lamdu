{-# LANGUAGE NoImplicitPrelude, FlexibleContexts, OverloadedStrings, TypeFamilies, RankNTypes, PatternGuards, RecordWildCards #-}
module Lamdu.Sugar.Convert.Binder
    ( convertBinder, convertLam
    ) where

import           Control.Lens (Lens')
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Lens.Tuple
import           Control.Monad (guard, void, when, join)
import           Control.MonadA (MonadA)
import           Data.CurAndPrev (CurAndPrev)
import           Data.Foldable (traverse_)
import qualified Data.List as List
import qualified Data.List.Utils as ListUtils
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe (fromMaybe)
import           Data.Maybe.Utils (unsafeUnjust)
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Store.Guid (Guid)
import           Data.Store.Property (Property)
import qualified Data.Store.Property as Property
import           Data.Store.Transaction (Transaction, MkProperty)
import qualified Data.Store.Transaction as Transaction
import qualified Lamdu.Builtins.Anchors as Builtins
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.Data.Ops.Subexprs as SubExprs
import           Lamdu.Eval.Val (ScopeId)
import qualified Lamdu.Eval.Val as EV
import qualified Lamdu.Expr.GenIds as GenIds
import           Lamdu.Expr.IRef (ValI, DefI, ValIProperty)
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Lens as ExprLens
import           Lamdu.Expr.Type (Type)
import qualified Lamdu.Expr.Type as T
import qualified Lamdu.Expr.UniqueId as UniqueId
import           Lamdu.Expr.Val (Val(..))
import qualified Lamdu.Expr.Val as V
import           Lamdu.Sugar.Convert.Expression.Actions (addActions, makeAnnotation)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Convert.ParamList (ParamList)
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import qualified Lamdu.Sugar.Lens as SugarLens
import           Lamdu.Sugar.OrderTags (orderedFlatComposite)
import           Lamdu.Sugar.Types

import           Prelude.Compat

type T = Transaction

data ConventionalParams m a = ConventionalParams
    { cpTags :: Set T.Tag
    , cpParamInfos :: Map T.Tag ConvertM.TagParamInfo
    , _cpParams :: BinderParams Guid m
    , cpMAddFirstParam :: Maybe (T m ParamAddResult)
    , cpScopes :: CurAndPrev (Map ScopeId [ScopeId])
    , cpMLamParam :: Maybe V.Var
    }

cpParams :: Lens' (ConventionalParams m a) (BinderParams Guid m)
cpParams f ConventionalParams {..} = f _cpParams <&> \_cpParams -> ConventionalParams{..}

data FieldParam = FieldParam
    { fpTag :: T.Tag
    , fpFieldType :: Type
    , fpValue :: CurAndPrev (Map ScopeId [(ScopeId, EV.EvalResult ())])
    }

data StoredLam m = StoredLam
    { _slLam :: V.Lam (Val (ValIProperty m))
    , slLambdaProp :: ValIProperty m
    }

slLam :: Lens' (StoredLam m) (V.Lam (Val (ValIProperty m)))
slLam f StoredLam{..} = f _slLam <&> \_slLam -> StoredLam{..}

mkStoredLam ::
    V.Lam (Val (Input.Payload m a)) ->
    Input.Payload m a -> Maybe (StoredLam m)
mkStoredLam lam pl =
    StoredLam
    <$> (lam & (traverse . traverse) (^. Input.mStored))
    <*> pl ^. Input.mStored

changeRecursionsFromCalls :: MonadA m => V.Var -> Val (ValIProperty m) -> T m ()
changeRecursionsFromCalls var =
    SubExprs.onMatchingSubexprs changeRecursion
    (V.body . ExprLens._BApp . V.applyFunc . ExprLens.valVar . Lens.only var)
    where
        changeRecursion prop =
            do
                body <- ExprIRef.readValBody (Property.value prop)
                case body of
                    V.BApp (V.Apply f _) -> Property.set prop f
                    _ -> error "assertion: expected BApp"

makeDeleteLambda ::
    MonadA m => Maybe V.Var -> StoredLam m ->
    ConvertM m (T m ParamDelResult)
makeDeleteLambda mRecursiveVar (StoredLam (V.Lam paramVar lamBodyStored) lambdaProp) =
    do
        protectedSetToVal <- ConvertM.typeProtectedSetToVal
        return $
            do
                SubExprs.getVarsToHole paramVar lamBodyStored
                mRecursiveVar
                    & Lens._Just %%~ (`changeRecursionsFromCalls` lamBodyStored)
                    & void
                let lamBodyI = Property.value (lamBodyStored ^. V.payload)
                _ <- protectedSetToVal lambdaProp lamBodyI
                return ParamDelResultDelVar

newTag :: MonadA m => T m T.Tag
newTag = GenIds.transaction GenIds.randomTag

isRecursiveCallArg :: V.Var -> [Val ()] -> Bool
isRecursiveCallArg recursiveVar (cur : parent : _) =
    Lens.allOf ExprLens.valVar (/= recursiveVar) cur &&
    Lens.anyOf (ExprLens.valApply . V.applyFunc . ExprLens.valVar)
    (== recursiveVar) parent
isRecursiveCallArg _ _ = False

-- TODO: find nicer way to do it than using properties and rereading
-- data?  Perhaps keep track of the up-to-date pure val as it is being
-- mutated?
rereadVal :: MonadA m => ValIProperty m -> T m (Val (ValIProperty m))
rereadVal valProp =
    ExprIRef.readVal (Property.value valProp)
    <&> fmap (flip (,) ())
    <&> ExprIRef.addProperties (Property.set valProp)
    <&> fmap fst

changeRecursiveCallArgs ::
    MonadA m =>
    (ValI m -> T m (ValI m)) ->
    ValIProperty m -> V.Var -> T m ()
changeRecursiveCallArgs change valProp var =
    -- Reread body before fixing it,
    -- to avoid re-writing old data (without converted vars)
    rereadVal valProp
    >>= SubExprs.onMatchingSubexprsWithPath changeRecurseArg (isRecursiveCallArg var)
    where
        changeRecurseArg prop =
            Property.value prop
            & change
            >>= Property.set prop

wrapArgWithRecord :: MonadA m => T.Tag -> T.Tag -> ValI m -> T m (ValI m)
wrapArgWithRecord tagForExistingArg tagForNewArg oldArg =
    do
        hole <- DataOps.newHole
        ExprIRef.newValBody (V.BLeaf V.LRecEmpty)
            >>= ExprIRef.newValBody . V.BRecExtend . V.RecExtend tagForNewArg hole
            >>= ExprIRef.newValBody . V.BRecExtend . V.RecExtend tagForExistingArg oldArg

convertVarToGetField ::
    MonadA m => T.Tag -> V.Var -> Val (Property (T m) (ValI m)) -> T m ()
convertVarToGetField tagForVar paramVar =
    SubExprs.onMatchingSubexprs (convertVar . Property.value)
    (ExprLens.valVar . Lens.only paramVar)
    where
        convertVar bodyI =
            ExprIRef.newValBody (V.BLeaf (V.LVar paramVar))
            <&> (`V.GetField` tagForVar) <&> V.BGetField
            >>= ExprIRef.writeValBody bodyI

data NewParamPosition = NewParamBefore | NewParamAfter

makeConvertToRecordParams ::
    MonadA m => Maybe V.Var -> StoredLam m ->
    ConvertM m (NewParamPosition -> T m ParamAddResult)
makeConvertToRecordParams mRecursiveVar (StoredLam (V.Lam paramVar lamBody) lamProp) =
    do
        wrapOnError <- ConvertM.wrapOnTypeError
        return $ \newParamPosition ->
            do
                tagForVar <- newTag
                tagForNewVar <- newTag
                setParamList paramList $ case newParamPosition of
                    NewParamBefore -> [tagForNewVar, tagForVar]
                    NewParamAfter -> [tagForVar, tagForNewVar]
                convertVarToGetField tagForVar paramVar lamBody
                mRecursiveVar
                    & traverse_
                        (changeRecursiveCallArgs
                          (wrapArgWithRecord tagForVar tagForNewVar)
                          (lamBody ^. V.payload))
                _ <- wrapOnError lamProp
                return $ ParamAddResultVarToTags VarToTags
                    { vttReplacedVar = paramVar
                    , vttReplacedVarEntityId = EntityId.ofLambdaParam paramVar
                    , vttReplacedByTag = tagGForLambdaTagParam paramVar tagForVar
                    , vttNewTag = tagGForLambdaTagParam paramVar tagForNewVar
                    }
    where
        paramList = Anchors.assocFieldParamList (Property.value lamProp)

tagGForLambdaTagParam :: V.Var -> T.Tag -> TagG ()
tagGForLambdaTagParam paramVar tag = TagG (EntityId.ofLambdaTagParam paramVar tag) tag ()

convertRecordParams ::
    (MonadA m, Monoid a) =>
    Maybe V.Var -> [FieldParam] ->
    V.Lam (Val (Input.Payload m a)) -> Input.Payload m a ->
    ConvertM m (ConventionalParams m a)
convertRecordParams mRecursiveVar fieldParams lam@(V.Lam param _) pl =
    do
        params <- traverse mkParam fieldParams
        mAddFirstParam <-
            mStoredLam
            & Lens.traverse %%~ makeAddFieldParam mRecursiveVar param (:tags)
        pure ConventionalParams
            { cpTags = Set.fromList tags
            , cpParamInfos = mconcat $ mkParamInfo <$> fieldParams
            , _cpParams = FieldParams params
            , cpMAddFirstParam = mAddFirstParam
            , cpScopes = pl ^. Input.evalResults <&> mkCpScopes
            , cpMLamParam = Just param
            }
    where
        tags = fpTag <$> fieldParams
        fpIdEntityId = EntityId.ofLambdaTagParam param . fpTag
        mkParamInfo fp =
            Map.singleton (fpTag fp) . ConvertM.TagParamInfo param $ fpIdEntityId fp
        mStoredLam = mkStoredLam lam pl
        mkParam fp =
            do
                actions <-
                    mStoredLam
                    & Lens.traverse %%~ makeFieldParamActions mRecursiveVar param tags fp
                pure
                    ( fpTag fp
                    , FuncParam
                        { _fpInfo =
                          NamedParamInfo
                          { _npiName = UniqueId.toGuid $ fpTag fp
                          , _npiMActions = actions
                          }
                        , _fpId = fpIdEntityId fp
                        , _fpAnnotation =
                            Annotation
                            { _aInferredType = fpFieldType fp
                            , _aMEvaluationResult =
                                fpValue fp <&>
                                \x ->
                                do
                                    Map.null x & not & guard
                                    x ^.. Lens.traversed . Lens.traversed
                                        & Map.fromList & Just
                            }
                        , _fpHiddenIds = []
                        }
                    )

mkCpScopes :: Input.EvalResultsForExpr -> Map ScopeId [ScopeId]
mkCpScopes x = x ^. Input.eAppliesOfLam <&> Lens.traversed %~ fst

setParamList :: MonadA m => MkProperty m (Maybe [T.Tag]) -> [T.Tag] -> T m ()
setParamList paramListProp newParamList =
    do
        zip newParamList [0..] & mapM_ (uncurry setParamOrder)
        Just newParamList & Transaction.setP paramListProp
    where
        setParamOrder = Transaction.setP . Anchors.assocTagOrder

makeAddFieldParam ::
    MonadA m =>
    Maybe V.Var -> V.Var -> (T.Tag -> ParamList) -> StoredLam m ->
    ConvertM m (T m ParamAddResult)
makeAddFieldParam mRecursiveVar param mkNewTags storedLam =
    do
        wrapOnError <- ConvertM.wrapOnTypeError
        return $
            do
                tag <- newTag
                mkNewTags tag & setParamList (slParamList storedLam)
                let addFieldToCall argI =
                        do
                            hole <- DataOps.newHole
                            ExprIRef.newValBody $ V.BRecExtend $ V.RecExtend tag hole argI
                mRecursiveVar
                    & Lens.traverse %%~
                        changeRecursiveCallArgs addFieldToCall
                        (storedLam ^. slLam . V.lamResult . V.payload)
                    & void
                void $ wrapOnError $ slLambdaProp storedLam
                return $
                    ParamAddResultNewTag $
                    TagG (EntityId.ofLambdaTagParam param tag) tag ()

makeFieldParamActions ::
    MonadA m =>
    Maybe V.Var -> V.Var -> [T.Tag] -> FieldParam -> StoredLam m ->
    ConvertM m (FuncParamActions m)
makeFieldParamActions mRecursiveVar param tags fp storedLam =
    do
        addParam <- makeAddFieldParam mRecursiveVar param mkNewTags storedLam
        delParam <- makeDelFieldParam mRecursiveVar tags fp storedLam
        pure FuncParamActions
            { _fpAddNext = addParam
            , _fpDelete = delParam
            }
    where
        mkNewTags tag =
            break (== fpTag fp) tags & \(pre, x:post) -> pre ++ [x, tag] ++ post

fixRecursiveCallRemoveField ::
    MonadA m =>
    T.Tag -> ValI m -> T m (ValI m)
fixRecursiveCallRemoveField tag argI =
    do
        body <- ExprIRef.readValBody argI
        case body of
            V.BRecExtend (V.RecExtend t v restI)
                | t == tag -> return restI
                | otherwise ->
                    do
                        newRestI <- fixRecursiveCallRemoveField tag restI
                        when (newRestI /= restI) $
                            ExprIRef.writeValBody argI $
                            V.BRecExtend $ V.RecExtend t v newRestI
                        return argI
            _ -> return argI

fixRecursiveCallToSingleArg ::
    MonadA m => T.Tag -> ValI m -> T m (ValI m)
fixRecursiveCallToSingleArg tag argI =
    do
        body <- ExprIRef.readValBody argI
        case body of
            V.BRecExtend (V.RecExtend t v restI)
                | t == tag -> return v
                | otherwise -> fixRecursiveCallToSingleArg tag restI
            _ -> return argI

getFieldOnVar :: Lens.Traversal' (Val t) (V.Var, T.Tag)
getFieldOnVar = V.body . ExprLens._BGetField . inGetField
    where
        inGetField f (V.GetField (Val pl (V.BLeaf (V.LVar v))) t) =
            pack pl <$> f (v, t)
        inGetField _ other = pure other
        pack pl (v, t) =
            V.GetField (Val pl (V.BLeaf (V.LVar v))) t

getFieldParamsToParams :: MonadA m => StoredLam m -> T.Tag -> T m ()
getFieldParamsToParams (StoredLam (V.Lam param lamBody) _) tag =
    SubExprs.onMatchingSubexprs (toParam . Property.value)
    (getFieldOnVar . Lens.only (param, tag)) lamBody
    where
        toParam bodyI = ExprIRef.writeValBody bodyI $ V.BLeaf $ V.LVar param

makeDelFieldParam ::
    MonadA m =>
    Maybe V.Var -> [T.Tag] -> FieldParam -> StoredLam m ->
    ConvertM m (T m ParamDelResult)
makeDelFieldParam mRecursiveVar tags fp storedLam =
    do
        wrapOnError <- ConvertM.wrapOnTypeError
        return $
            do
                Transaction.setP (slParamList storedLam) newTags
                getFieldParamsToHole tag storedLam
                mLastTag
                    & traverse_ (getFieldParamsToParams storedLam)
                mRecursiveVar
                    & traverse_
                        (changeRecursiveCallArgs fixRecurseArg
                          (storedLam ^. slLam . V.lamResult . V.payload))
                _ <- wrapOnError $ slLambdaProp storedLam
                return delResult
    where
        paramVar = storedLam ^. slLam . V.lamParamId
        tag = fpTag fp
        fixRecurseArg =
            maybe (fixRecursiveCallRemoveField tag)
            fixRecursiveCallToSingleArg mLastTag
        (newTags, mLastTag, delResult) =
            case List.delete tag tags of
            [x] ->
                ( Nothing
                , Just x
                , ParamDelResultTagsToVar TagsToVar
                    { ttvReplacedTag = tagGForLambdaTagParam paramVar x
                    , ttvReplacedByVar = paramVar
                    , ttvReplacedByVarEntityId = EntityId.ofLambdaParam paramVar
                    , ttvDeletedTag = tagGForLambdaTagParam paramVar tag
                    }
                )
            xs -> (Just xs, Nothing, ParamDelResultDelTag)

slParamList :: MonadA m => StoredLam m -> Transaction.MkProperty m (Maybe ParamList)
slParamList = Anchors.assocFieldParamList . Property.value . slLambdaProp

makeNonRecordParamActions ::
    MonadA m => Maybe V.Var -> StoredLam m ->
    ConvertM m (FuncParamActions m, T m ParamAddResult)
makeNonRecordParamActions mRecursiveVar storedLam =
    do
        delete <- makeDeleteLambda mRecursiveVar storedLam
        convertToRecordParams <- makeConvertToRecordParams mRecursiveVar storedLam
        return
            ( FuncParamActions
                { _fpAddNext = convertToRecordParams NewParamAfter
                , _fpDelete = delete
                }
            , convertToRecordParams NewParamBefore
            )

lamParamType :: Input.Payload m a -> Type
lamParamType lamExprPl =
    unsafeUnjust "Lambda value not inferred to a function type?!" $
    lamExprPl ^? Input.inferredType . ExprLens._TFun . _1

mkFuncParam :: EntityId -> Input.Payload m a -> info -> FuncParam info
mkFuncParam paramEntityId lamExprPl info =
    FuncParam
    { _fpInfo = info
    , _fpId = paramEntityId
    , _fpAnnotation =
        Annotation
        { _aInferredType = lamParamType lamExprPl
        , _aMEvaluationResult =
            lamExprPl ^. Input.evalResults
            <&> (^. Input.eAppliesOfLam)
            <&> \lamApplies ->
            do
                Map.null lamApplies & not & guard
                lamApplies ^..
                    Lens.traversed . Lens.traversed & Map.fromList & Just
        }
    , _fpHiddenIds = []
    }

convertNonRecordParam ::
    MonadA m => Maybe V.Var ->
    V.Lam (Val (Input.Payload m a)) -> Input.Payload m a ->
    ConvertM m (ConventionalParams m a)
convertNonRecordParam mRecursiveVar lam@(V.Lam param _) lamExprPl =
    do
        mActions <- mStoredLam & Lens._Just %%~ makeNonRecordParamActions mRecursiveVar
        let funcParam =
                case lamParamType lamExprPl of
                T.TRecord T.CEmpty
                    | isParamUnused lam ->
                      mActions
                      <&> (^. _1 . fpDelete)
                      <&> void
                      <&> NullParamActions
                      & NullParamInfo
                      & mkFuncParam paramEntityId lamExprPl & NullParam
                _ ->
                    NamedParamInfo
                    { _npiName = UniqueId.toGuid param
                    , _npiMActions = mActions <&> fst
                    } & mkFuncParam paramEntityId lamExprPl & VarParam
        pure ConventionalParams
            { cpTags = mempty
            , cpParamInfos = Map.empty
            , _cpParams = funcParam
            , cpMAddFirstParam = mActions <&> snd
            , cpScopes = lamExprPl ^. Input.evalResults <&> mkCpScopes
            , cpMLamParam = Just param
            }
    where
        mStoredLam = mkStoredLam lam lamExprPl
        paramEntityId = EntityId.ofLambdaParam param

isParamAlwaysUsedWithGetField :: V.Lam (Val a) -> Bool
isParamAlwaysUsedWithGetField (V.Lam param body) =
    Lens.nullOf (ExprLens.payloadsIndexedByPath . Lens.ifiltered cond) body
    where
        cond (_ : Val () V.BGetField{} : _) _ = False
        cond (Val () (V.BLeaf (V.LVar v)) : _) _ = v == param
        cond _ _ = False

-- TODO: move to eval vals
extractField :: T.Tag -> EV.EvalResult pl -> EV.EvalResult pl
extractField _ (Left err) = Left err
extractField tag (Right (EV.HRecExtend (V.RecExtend vt vv vr)))
    | vt == tag = vv
    | otherwise = extractField tag vr
extractField tag (Right x) =
    "Expected record with tag: " ++ show tag ++ " got: " ++ show (void x)
    & EV.EvalTypeError & Left

isParamUnused :: V.Lam (Val a) -> Bool
isParamUnused (V.Lam var body) =
    Lens.allOf (ExprLens.valLeafs . ExprLens._LVar) (/= var) body

convertLamParams ::
    (MonadA m, Monoid a) =>
    Maybe V.Var ->
    V.Lam (Val (Input.Payload m a)) -> Input.Payload m a ->
    ConvertM m (ConventionalParams m a)
convertLamParams mRecursiveVar lambda lambdaPl =
    do
        tagsInOuterScope <-
            ConvertM.readContext <&> Map.keysSet . (^. ConvertM.scScopeInfo . ConvertM.siTagParamInfos)
        case lambdaPl ^. Input.inferredType of
            T.TFun (T.TRecord composite) _
                | Nothing <- extension
                , ListUtils.isLengthAtLeast 2 fields
                , Set.null (tagsInOuterScope `Set.intersection` tagsInInnerScope)
                , isParamAlwaysUsedWithGetField lambda ->
                    convertRecordParams mRecursiveVar fieldParams lambda lambdaPl
                where
                    tagsInInnerScope = Set.fromList $ fst <$> fields
                    (fields, extension) = orderedFlatComposite composite
                    fieldParams = map makeFieldParam fields
            _ -> convertNonRecordParam mRecursiveVar lambda lambdaPl
    where
        makeFieldParam (tag, typeExpr) =
            FieldParam
            { fpTag = tag
            , fpFieldType = typeExpr
            , fpValue =
                    lambdaPl ^. Input.evalResults
                    <&> (^. Input.eAppliesOfLam)
                    <&> Lens.traversed . Lens.mapped . Lens._2 %~ extractField tag
            }

convertEmptyParams :: MonadA m =>
    Maybe V.Var -> Val (Input.Payload m a) -> ConvertM m (ConventionalParams m a)
convertEmptyParams mRecursiveVar val =
    do
        protectedSetToVal <- ConvertM.typeProtectedSetToVal
        let makeAddFirstParam storedVal =
                do
                    (newParam, dst) <- DataOps.lambdaWrap (storedVal ^. V.payload)
                    case mRecursiveVar of
                        Nothing -> return ()
                        Just recursiveVar -> changeRecursionsToCalls recursiveVar storedVal
                    void $ protectedSetToVal (storedVal ^. V.payload) dst
                    return $
                        ParamAddResultNewVar (EntityId.ofLambdaParam newParam) newParam

        pure
            ConventionalParams
            { cpTags = mempty
            , cpParamInfos = Map.empty
            , _cpParams = DefintionWithoutParams
            , cpMAddFirstParam =
                val
                <&> (^. Input.mStored)
                & sequenceA
                & Lens._Just %~ makeAddFirstParam
            , cpScopes =
                -- Collect scopes from all evaluated subexpressions.
                val ^.. ExprLens.subExprPayloads . Input.evalResults
                & sequenceA
                <&> (^.. Lens.traversed . Input.eResults . Lens.to Map.keys . Lens.traversed)
                <&> Lens.traversed %~ join (,)
                <&> Map.fromList
                <&> Lens.traversed %~ (:[])
            , cpMLamParam = Nothing
            }

convertParams ::
    (MonadA m, Monoid a) =>
    Maybe V.Var -> Val (Input.Payload m a) ->
    ConvertM m
    ( ConventionalParams m a
    , Val (Input.Payload m a)
    )
convertParams mRecursiveVar expr =
    case expr ^. V.body of
    V.BAbs lambda ->
        do
            params <-
                convertLamParams mRecursiveVar lambda (expr ^. V.payload)
                -- The lambda disappears here, so add its id to the first
                -- param's hidden ids:
                <&> cpParams . _VarParam . fpHiddenIds <>~ hiddenIds
                <&> cpParams . _FieldParams . Lens.ix 0 . _2 . fpHiddenIds <>~ hiddenIds
            return (params, lambda ^. V.lamResult)
        where
              hiddenIds = [expr ^. V.payload . Input.entityId]
    _ ->
        do
            params <- convertEmptyParams mRecursiveVar expr
            return (params, expr)

changeRecursionsToCalls :: MonadA m => V.Var -> Val (ValIProperty m) -> T m ()
changeRecursionsToCalls var =
    SubExprs.onMatchingSubexprs changeRecursion (ExprLens.valVar . Lens.only var)
    where
        changeRecursion prop =
            DataOps.newHole
            >>= ExprIRef.newValBody . V.BApp . V.Apply (Property.value prop)
            >>= Property.set prop

data Redex a = Redex
    { redexBody :: Val a
    , redexBodyScope :: CurAndPrev (Map ScopeId ScopeId)
    , redexParam :: V.Var
    , redexArg :: Val a
    , redexHiddenPayloads :: [a]
    , redexArgAnnotation :: Annotation
    }

checkForRedex :: Val (Input.Payload m a) -> Maybe (Redex (Input.Payload m a))
checkForRedex expr = do
    V.Apply func arg <- expr ^? ExprLens.valApply
    V.Lam param body <- func ^? V.body . ExprLens._BAbs
    Just Redex
        { redexBody = body
        , redexBodyScope =
            func ^. V.payload . Input.evalResults
            <&> (^. Input.eAppliesOfLam)
            <&> Lens.traversed %~ getRedexApplies
        , redexParam = param
        , redexArg = arg
        , redexHiddenPayloads = (^. V.payload) <$> [expr, func]
        , redexArgAnnotation = makeAnnotation (arg ^. V.payload)
        }
    where
        getRedexApplies [(scopeId, _)] = scopeId
        getRedexApplies _ =
            error "redex should only be applied once per parent scope"


getFieldParamsToHole :: MonadA m => T.Tag -> StoredLam m -> T m ()
getFieldParamsToHole tag (StoredLam (V.Lam param lamBody) _) =
    SubExprs.onMatchingSubexprs SubExprs.toHole (getFieldOnVar . Lens.only (param, tag)) lamBody

-- Move let item one level outside
letItemToOutside ::
    MonadA m =>
    Maybe (ValIProperty m) ->
    Maybe (DefI m) ->
    Anchors.CodeProps m ->
    [V.Var] -> V.Var -> T m () ->
    Val (ValIProperty m) -> Val (ValIProperty m) ->
    T m EntityId
letItemToOutside mExtractDestPos mRecursiveDefI cp binderScopeVars param delItem bodyStored argStored =
    do
        mapM_ (`SubExprs.getVarsToHole` argStored) binderScopeVars
        delItem
        case mExtractDestPos of
            Nothing ->
                do
                    paramName <- Anchors.assocNameRef param & Transaction.getP
                    SubExprs.onGetVars
                        (SubExprs.toGetGlobal
                         (fromMaybe (error "recurseVar used not in definition context?!") mRecursiveDefI))
                        Builtins.recurseVar argStored
                    newDefI <- DataOps.newPublicDefinitionWithPane paramName cp extractedI
                    SubExprs.onGetVars (SubExprs.toGetGlobal newDefI) param bodyStored
                    EntityId.ofIRef newDefI & return
            Just scopeBodyP ->
                EntityId.ofLambdaParam param <$
                DataOps.redexWrapWithGivenParam param extractedI scopeBodyP
    where
        extractedI = argStored ^. V.payload & Property.value

mkLIActions ::
    MonadA m =>
    [V.Var] -> V.Var -> ValIProperty m ->
    Val (ValIProperty m) -> Val (ValIProperty m) ->
    ConvertM m (LetActions m)
mkLIActions binderScopeVars param topLevelProp bodyStored argStored =
    do
        ctx <- ConvertM.readContext
        return
            LetActions
            { _laSetToInner = SubExprs.getVarsToHole param bodyStored >> del
            , _laSetToHole = DataOps.setToHole topLevelProp <&> EntityId.ofValI
            , _laAddNext =
              DataOps.redexWrap topLevelProp <&> EntityId.ofLambdaParam . fst
            , _laExtract =
              letItemToOutside
              (ctx ^. ConvertM.scMExtractDestPos)
              (ctx ^. ConvertM.scDefI)
              (ctx ^. ConvertM.scCodeAnchors)
              binderScopeVars param del bodyStored argStored
            }
    where
        del = bodyStored ^. V.payload & replaceWith topLevelProp & void

localExtractDestPost :: MonadA m => Val (Input.Payload m x) -> ConvertM m a -> ConvertM m a
localExtractDestPost val =
    ConvertM.scMExtractDestPos .~ val ^. V.payload . Input.mStored
    & ConvertM.local

makeBinderBody ::
    (MonadA m, Monoid a) =>
    [V.Var] -> Val (Input.Payload m a) ->
    ConvertM m
    ( Val (Input.Payload m a)
    , BinderContent Guid m (ExpressionU m a)
    )
makeBinderBody binderScopeVars expr =
    case checkForRedex expr of
    Nothing ->
        do
            exprS <- ConvertM.convertSubexpression expr & localExtractDestPost expr
            return (expr, BinderExpr exprS)
    Just redex ->
        do
            value <-
                convertBinder Nothing defGuid (redexArg redex)
                & localExtractDestPost expr
            actions <-
                mkLIActions binderScopeVars param
                <$> expr ^. V.payload . Input.mStored
                <*> traverse (^. Input.mStored) (redexBody redex)
                <*> traverse (^. Input.mStored) (redexArg redex)
                & Lens.sequenceOf Lens._Just
            (innerBody, body) <-
                makeBinderBody (redexParam redex : binderScopeVars) (redexBody redex)
            return
                ( innerBody
                , BinderLet
                  Let
                  { _lEntityId = defEntityId
                  , _lValue =
                      value
                      & bBody . SugarLens.binderContentExpr . rPayload . plData <>~
                      redexHiddenPayloads redex ^. Lens.traversed . Input.userData
                  , _lActions = actions
                  , _lName = UniqueId.toGuid param
                  , _lAnnotation = redexArgAnnotation redex
                  , _lBodyScope = redexBodyScope redex
                  , _lBody = body
                  }
                )
        where
            param = redexParam redex
            defGuid = UniqueId.toGuid param
            defEntityId = EntityId.ofLambdaParam param

makeBinder :: (MonadA m, Monoid a) =>
    Maybe (MkProperty m (Maybe BinderParamScopeId)) ->
    Maybe (MkProperty m PresentationMode) ->
    ConventionalParams m a -> Val (Input.Payload m a) ->
    ConvertM m (Binder Guid m (ExpressionU m a))
makeBinder mChosenScopeProp mPresentationModeProp ConventionalParams{..} funcBody =
    do
        (innerMostLetBody, binderBody) <- makeBinderBody ourParams funcBody
        return Binder
            { _bParams = _cpParams
            , _bMPresentationModeProp = mPresentationModeProp
            , _bMChosenScopeProp = mChosenScopeProp
            , _bBody = binderBody
            , _bBodyScopes =
              cpScopes <&> Lens.mapped . Lens.traversed %~ BinderParamScopeId
            , _bMActions =
                mkActions
                <$> cpMAddFirstParam
                <*> innerMostLetBody ^. V.payload . Input.mStored
            }
    & ConvertM.local (ConvertM.scScopeInfo %~ addParams)
    where
        ourParams = cpMLamParam ^.. Lens._Just
        addParams ctx =
            ctx
            & ConvertM.siTagParamInfos <>~ cpParamInfos
            & ConvertM.siNullParams <>~
            case _cpParams of
            NullParam {} -> Set.fromList (cpMLamParam ^.. Lens._Just)
            _ -> Set.empty
        mkActions addFirstParam letStored =
            BinderActions
            { _baAddFirstParam = addFirstParam
            , _baAddInnermostLet =
                    EntityId.ofLambdaParam . fst <$> DataOps.redexWrap letStored
            }

convertLam ::
    (MonadA m, Monoid a) =>
    V.Lam (Val (Input.Payload m a)) ->
    Input.Payload m a -> ConvertM m (ExpressionU m a)
convertLam lam@(V.Lam _ lamBody) exprPl =
    do
        mDeleteLam <- mkStoredLam lam exprPl & Lens._Just %%~ makeDeleteLambda Nothing
        convParams <- convertLamParams Nothing lam exprPl
        binder <-
            makeBinder
            (exprPl ^. Input.mStored <&> Anchors.assocScopeRef . Property.value)
            Nothing convParams (lam ^. V.lamResult)
        let setToInnerExprAction =
                maybe NoInnerExpr SetToInnerExpr $
                do
                    guard $ Lens.nullOf ExprLens.valHole lamBody
                    mDeleteLam
                        <&> Lens.mapped .~ binder ^. bBody . SugarLens.binderContentExpr . rPayload . plEntityId
        let paramSet =
                binder ^.. bParams . SugarLens.binderNamedParams .
                Lens.traversed . npiName
                & Set.fromList
        let lambda
                | useNormalLambda binder =
                    Lambda NormalBinder binder
                | otherwise =
                    binder
                    & bBody . Lens.traverse %~ markLightParams paramSet
                    & Lambda LightLambda
        BodyLam lambda
            & addActions exprPl
            <&> rPayload . plActions . Lens._Just . setToInnerExpr .~ setToInnerExprAction

useNormalLambda :: Binder name m (Expression name m a) -> Bool
useNormalLambda binder =
    or
    [ Lens.has (bBody . _BinderLet) binder
    , Lens.has (bBody . Lens.traverse . SugarLens.payloadsOf forbiddenLightLamSubExprs) binder
    , Lens.nullOf (bParams . _FieldParams) binder
    ]
    where
        forbiddenLightLamSubExprs :: Lens.Fold (Body name m a) ()
        forbiddenLightLamSubExprs =
            Lens.failing (_BodyHole . check)
            (_BodyLam . lamBinder . bParams . SugarLens.binderNamedParams .
                check)
        check :: Lens.Fold a ()
        check = const () & Lens.to

markLightParams ::
    MonadA m => Set Guid -> ExpressionU m a -> ExpressionU m a
markLightParams paramNames (Expression body pl) =
    case body of
    BodyGetVar (GetVarNamed n)
        | Set.member (n ^. nvNameRef . nrName) paramNames ->
            n
            & nvMode .~ LightLambda
            & GetVarNamed & BodyGetVar
    BodyHole h ->
        h
        & holeMActions . Lens._Just
        . holeOptions . Lens.mapped . Lens.traversed . hoResults
        . Lens.mapped . _2 . Lens.mapped . holeResultConverted
            %~ markLightParams paramNames
        & BodyHole
    _ -> body <&> markLightParams paramNames
    & (`Expression` pl)

-- Let-item or definition (form of <name> [params] = <body>)
convertBinder ::
    (MonadA m, Monoid a) =>
    Maybe V.Var -> Guid ->
    Val (Input.Payload m a) -> ConvertM m (Binder Guid m (ExpressionU m a))
convertBinder mRecursiveVar defGuid expr =
    do
        (convParams, funcBody) <- convertParams mRecursiveVar expr
        let mPresentationModeProp
                | Lens.has (cpParams . _FieldParams) convParams =
                    Just $ Anchors.assocPresentationMode defGuid
                | otherwise = Nothing
        makeBinder (Just (Anchors.assocScopeRef defGuid)) mPresentationModeProp
            convParams funcBody
