{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Lamdu.GUI.TypeView
  ( make
  ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Lens.Operators
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.State (StateT, state, evalStateT)
import Control.MonadA (MonadA)
import Data.Map (Map)
import Data.Monoid (Monoid(..))
import Data.Store.Transaction (Transaction)
import Data.Vector.Vector2 (Vector2(..))
import Graphics.UI.Bottle.Animation (AnimId)
import Graphics.UI.Bottle.View (View)
import Lamdu.Expr.FlatComposite (FlatComposite(..))
import Lamdu.Expr.Identifier (Identifier(..))
import Lamdu.Expr.Type (Type)
import Lamdu.GUI.Precedence (ParentPrecedence(..), MyPrecedence(..))
import Lamdu.GUI.WidgetEnvT (WidgetEnvT)
import System.Random (Random, random)
import qualified Control.Lens as Lens
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Map as Map
import qualified Graphics.UI.Bottle.Animation as Anim
import qualified Graphics.UI.Bottle.View as View
import qualified Graphics.UI.Bottle.WidgetId as WidgetId
import qualified Graphics.UI.Bottle.Widgets.GridView as GridView
import qualified Graphics.UI.Bottle.Widgets.Spacer as Spacer
import qualified Lamdu.Expr.FlatComposite as FlatComposite
import qualified Lamdu.Expr.Type as T
import qualified Lamdu.GUI.BottleWidgets as BWidgets
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified System.Random as Random

showIdentifier :: Identifier -> String
showIdentifier (Identifier bs) = BS8.unpack bs

type T = Transaction
newtype M m a = M
  { runM :: StateT Random.StdGen (WidgetEnvT (T m)) a
  } deriving (Functor, Applicative, Monad)
wenv :: Monad m => WidgetEnvT (T m) a -> M m a
wenv = M . lift
rand :: (Random r, Monad m) => M m r
rand = M $ state random
split :: Monad m => M m a -> M m a
split (M act) =
  do
    splitGen <- M $ state Random.split
    M $ lift $ evalStateT act splitGen

randAnimId :: MonadA m => M m AnimId
randAnimId = WidgetId.toAnimId . WidgetIds.fromGuid <$> rand

text :: MonadA m => String -> M m View
text str = wenv . BWidgets.makeTextView str =<< randAnimId

hbox :: [View] -> View
hbox = GridView.horizontalAlign 0.5

space :: View
space = Spacer.makeHorizontal 20

parensAround :: MonadA m => View -> M m View
parensAround view =
  do
    openParenView <- text "("
    closeParenView <- text ")"
    return $ hbox [openParenView, view, closeParenView]

parens ::
  MonadA m => ParentPrecedence -> MyPrecedence -> View -> M m View
parens (ParentPrecedence parent) (MyPrecedence my) view
  | parent > my = parensAround view
  | otherwise = return view

makeTVar :: MonadA m => T.Var p -> M m View
makeTVar (T.Var name) = text (showIdentifier name)

makeTFun :: MonadA m => ParentPrecedence -> Type -> Type -> M m View
makeTFun parentPrecedence a b =
  parens parentPrecedence (MyPrecedence 0) =<<
  hbox <$> sequence
  [ splitMake (ParentPrecedence 1) a
  , text " -> "
  , splitMake (ParentPrecedence 0) b
  ]

makeTInst :: MonadA m => ParentPrecedence -> T.Id -> Map T.ParamId Type -> M m View
makeTInst _parentPrecedence (T.Id name) typeParams =
  do
    nameView <- text (showIdentifier name)
    case Map.toList typeParams of
      [] -> pure nameView
      ((_, arg) : []) ->
        do
          argView <- makeInternal (ParentPrecedence 0) arg
          pure $ hbox [nameView, space, argView]
      _ ->
        do
          t <- text " [TODO multiple args]"
          pure $ hbox [nameView, t]

makeRecord :: MonadA m => T.Composite T.Product -> M m View
makeRecord composite =
  do
    rows <-
      sequence $ do
        (tag, fieldType) <- Map.toList fields
        return $ do
          tagView <- text "TAG"
          typeView <- makeInternal (ParentPrecedence 0) fieldType
          return
            [ (Vector2 1 0.5, tagView)
            , (0.5, space)
            , (Vector2 0 0.5, typeView)
            ]
    let
      fieldsView = GridView.make rows
      barWidth =
        case rows of
        [] -> 150
        _ -> fieldsView ^. Lens._1 . Lens._1
    sqr <-
      randAnimId
      <&>
        case extension of
        Nothing -> Anim.unitSquare
        Just _ -> Anim.unitHStripedSquare 20
      <&> (,) 1
      <&> (^. View.scaled (Vector2 barWidth 10))
    varView <-
      case extension of
      Nothing -> pure (0, mempty)
      Just var -> makeTVar var
    return $ GridView.verticalAlign 0.5 [fieldsView, sqr, varView]
  where
    FlatComposite fields extension = FlatComposite.fromComposite composite

splitMake :: MonadA m => ParentPrecedence -> Type -> M m View
splitMake parentPrecedence typ = split $ makeInternal parentPrecedence typ

makeInternal :: MonadA m => ParentPrecedence -> Type -> M m View
makeInternal parentPrecedence typ =
  case typ of
  T.TVar var -> makeTVar var
  T.TFun a b -> makeTFun parentPrecedence a b
  T.TInst typeId typeParams -> makeTInst parentPrecedence typeId typeParams
  T.TRecord composite -> makeRecord composite

make :: MonadA m => Random.StdGen -> Type -> WidgetEnvT (T m) View
make gen = (`evalStateT` gen) . runM . makeInternal (ParentPrecedence 0)
