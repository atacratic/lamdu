-- | "if" sugar/guards conversion
module Lamdu.Sugar.Convert.IfElse (convertIfElse) where

import qualified Control.Lens as Lens
import qualified Data.Property as Property
import           Lamdu.Builtins.Anchors (boolTid, trueTag, falseTag)
import           Lamdu.Data.Anchors (bParamScopeId)
import           Lamdu.Expr.IRef (ValI)
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types
import           Revision.Deltum.Transaction (Transaction)

import           Lamdu.Prelude

type T = Transaction

convertIfElse ::
    Functor m =>
    (ValI m -> T m (ValI m)) ->
    Case InternalName (T m) (T m) (ExpressionU m a) ->
    Maybe (IfElse InternalName (T m) (T m) (ExpressionU m a))
convertIfElse setToVal caseBody =
    do
        arg <- caseBody ^? cKind . _CaseWithArg . caVal
        case arg ^. body of
            BodyFromNom nom | nom ^. nTId . tidTId == boolTid -> tryIfElse (nom ^. nVal)
            _ | arg ^? annotation . pSugar . plAnnotation . aInferredType . tBody . _TInst . _1 . tidTId == Just boolTid -> tryIfElse arg
            _ -> Nothing
    where
        tryIfElse cond =
            case caseBody ^. cBody . cItems of
            [alt0, alt1]
                | tagOf alt0 == trueTag && tagOf alt1 == falseTag -> convIfElse cond alt0 alt1
                | tagOf alt1 == trueTag && tagOf alt0 == falseTag -> convIfElse cond alt1 alt0
            _ -> Nothing
        tagOf alt = alt ^. ciTag . tagInfo . tagVal
        convIfElse cond altTrue altFalse =
            case mAltFalseBinder of
            Just binder ->
                case binder ^? fBody . bbContent . _BinderExpr of
                Just altFalseBinderExpr ->
                    case altFalseBinderExpr ^. body of
                    BodyIfElse innerIfElse ->
                        ElseIf ElseIfContent
                        { _eiScopes =
                            case binder ^. fBodyScopes of
                            SameAsParentScope -> error "lambda body should have scopes"
                            BinderBodyScope x -> x <&> Lens.mapped %~ getScope
                        , _eiEntityId = altFalseBinderExpr ^. annotation . pSugar . plEntityId
                        , _eiContent = innerIfElse
                        , _eiCondAddLet = binder ^. fBody . bbAddOuterLet
                        , _eiNodeActions = altFalseBinderExpr ^. annotation . pSugar . plActions
                        }
                        & makeRes
                        where
                            getScope [x] = x ^. bParamScopeId
                            getScope _ = error "if-else evaluated more than once in same scope?"
                    _ -> simpleIfElse
                Nothing -> simpleIfElse
            Nothing -> simpleIfElse
            & Just
            where
                mAltFalseBinder = altFalse ^? ciExpr . body . _BodyLam . lamFunc
                simpleIfElse =
                    altFalse ^. ciExpr
                    & body . _BodyHole . holeMDelete ?~ elseDel
                    & body . _BodyLam . lamFunc . fBody . bbContent . _BinderExpr
                        . body . _BodyHole . holeMDelete ?~ elseDel
                    & SimpleElse
                    & makeRes
                elseDel = setToVal (delTarget altTrue) <&> EntityId.ofValI
                delTarget alt =
                    alt ^? ciExpr . body . _BodyLam . lamFunc . fBody . bbContent . _BinderExpr
                    & fromMaybe (alt ^. ciExpr)
                    & (^. annotation . pStored . Property.pVal)
                makeRes els =
                    IfElse
                    { _iIfThen =
                        IfThen
                        { _itIf = cond
                        , _itThen = altTrue ^. ciExpr
                        , _itDelete = delTarget altFalse & setToVal <&> EntityId.ofValI
                        }
                    , _iElse = els
                    }

