{-# LANGUAGE NoImplicitPrelude #-}
module Lamdu.Sugar.Convert.Record
    ( convertEmpty, convertExtend
    ) where

import qualified Control.Lens as Lens
import qualified Lamdu.Calc.Val as V
import           Lamdu.Calc.Val.Annotated (Val(..))
import qualified Lamdu.Calc.Val.Annotated as Val
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.Expr.IRef as ExprIRef
import           Lamdu.Sugar.Convert.Composite (convertCompositeItem, makeAddItem)
import           Lamdu.Sugar.Convert.Expression.Actions (addActions)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Convert.Tag (convertTagSelection)
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types
import qualified Revision.Deltum.Property as Property

import           Lamdu.Prelude

plValI :: Lens.Lens' (Input.Payload m a) (ExprIRef.ValI m)
plValI = Input.stored . Property.pVal

convertEmpty :: Monad m => Input.Payload m a -> ConvertM m (ExpressionU m a)
convertEmpty exprPl =
    do
        addItem <- exprPl ^. Input.stored & makeAddItem DataOps.recExtend 0
        postProcess <- ConvertM.postProcess
        let actions =
                ClosedCompositeActions
                { _closedCompositeOpen =
                    DataOps.replaceWithHole (exprPl ^. Input.stored)
                    <* postProcess
                    <&> EntityId.ofValI
                }
        addItemWithTag <-
            convertTagSelection mempty (EntityId.ofTag (exprPl ^. Input.entityId)) addItem
            <&> Lens.mapped %~ (^. cairNewVal)
        BodyRecord Composite
            { _cItems = []
            , _cTail = ClosedComposite actions
            , _cAddItem = addItemWithTag
            }
            & addActions exprPl

convertExtend ::
    (Monad m, Monoid a) => V.RecExtend (Val (Input.Payload m a)) ->
    Input.Payload m a -> ConvertM m (ExpressionU m a)
convertExtend (V.RecExtend tag val rest) exprPl = do
    restS <- ConvertM.convertSubexpression rest
    (restRecord, modifyEntityId) <-
        case restS ^. rBody of
        BodyRecord r ->
            pure (r, const (restS ^. rPayload . plEntityId))
        _ ->
            do
                addField <- makeAddItem DataOps.recExtend 1 restStored
                protectedSetToVal <- ConvertM.typeProtectedSetToVal
                let actions =
                        OpenCompositeActions
                        { _openCompositeClose =
                            ExprIRef.newValBody (V.BLeaf V.LRecEmpty)
                            >>= protectedSetToVal restStored
                            <&> EntityId.ofValI
                        }
                addItemWithTag <-
                    convertTagSelection mempty (EntityId.ofTag tagInstSource) addField
                    <&> Lens.mapped %~ (^. cairNewVal)
                pure
                    ( Composite
                        { _cItems = []
                        , _cTail = OpenComposite actions restS
                        , _cAddItem = addItemWithTag
                        }
                    , id
                    )
    fieldS <-
        convertCompositeItem
        (V.RecExtend <&> Lens.mapped . Lens.mapped %~ V.BRecExtend)
        (exprPl ^. Input.stored) (rest ^. Val.payload . plValI)
        tagInstSource tag val
    restRecord
        & cItems %~ (fieldS:)
        & BodyRecord
        & addActions exprPl
        <&> rPayload . plEntityId %~ modifyEntityId
    where
        restStored = rest ^. Val.payload . Input.stored
        -- Tag instance is based on extended expr,
        -- because we need to know it when offering the selection of the new tag,
        -- (before this rec-extend exists).
        tagInstSource = rest ^. Val.payload . Input.entityId
