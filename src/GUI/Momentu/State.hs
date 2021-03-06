-- Suppress wrong warning on default instance for default `cursor` method.
-- TODO: Check if GHC bug reported on that.
{-# OPTIONS_GHC -Wno-redundant-constraints  #-}

{-# LANGUAGE TemplateHaskell, DefaultSignatures #-}

module GUI.Momentu.State
    ( VirtualCursor(..), vcRect
    , GUIState(..), sCursor, sWidgetStates
    , Update(..), uCursor, uPreferStroll, uWidgetStateUpdates, uVirtualCursor
    , Gui
    , update
    , updateCursor, fullUpdate
    , HasCursor(..), subId, isSubCursor, assignCursor, assignCursorPrefix
    , HasState(..), readWidgetState, updateWidgetState
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Data.Binary.Extended (Binary, decodeOrFail, encodeS)
import           Data.ByteString.Extended as BS
import qualified Data.Map as Map
import qualified Data.Monoid as Monoid
import           Data.Monoid.Generic (def_mempty, def_mappend)
import           GUI.Momentu.Animation.Id (AnimId)
import           GUI.Momentu.Rect (Rect)
import           GUI.Momentu.Widget.Id (Id(..))
import qualified GUI.Momentu.Widget.Id as Id

import           Lamdu.Prelude

-- The virtual cursor is the focal area that would ideally match the
-- direction of user movements
newtype VirtualCursor = VirtualCursor { _vcRect :: Rect }
Lens.makeLenses ''VirtualCursor

-- The GUIState may persist in user-specified storage (e.g: the Lamdu
-- DB), thus we do not want to store the virtual cursor there. The
-- Update type is still a convenient place to carry the virtual cursor
-- updates.

data GUIState = GUIState
    { _sCursor :: Id
    , _sWidgetStates :: Map Id ByteString
    } deriving Generic
instance Binary GUIState
Lens.makeLenses ''GUIState

data Update = Update
    { _uCursor :: Monoid.Last Id
    , _uPreferStroll :: Monoid.Any
    , _uWidgetStateUpdates :: Map Id ByteString
    , _uVirtualCursor :: Monoid.Last VirtualCursor
    } deriving Generic
Lens.makeLenses ''Update

instance Semigroup Update where
    (<>) = def_mappend

instance Monoid Update where
    mempty = def_mempty
    mappend = (<>)

type Gui w f = w (f Update)

updateCursor :: Id -> Update
updateCursor c = mempty { _uCursor = Just c & Monoid.Last }

fullUpdate :: GUIState -> Update
fullUpdate (GUIState c s) = updateCursor c & uWidgetStateUpdates .~ s

update :: HasState env => Update -> env -> env
update u s =
    case u ^? uCursor . Lens._Wrapped . Lens._Just of
    Nothing -> s
    Just c ->
        s
        & state . sCursor .~ c
        & state . sWidgetStates %~ Map.filterWithKey f
        where
            f k _v = Id.subId k c & Lens.has Lens._Just
    & state . sWidgetStates %~ mappend (u ^. uWidgetStateUpdates)

class HasCursor env where
    cursor :: Lens' env Id
    default cursor :: HasState env => Lens' env Id
    cursor = state . sCursor

instance HasCursor GUIState where cursor = sCursor

subId :: (MonadReader env m, HasCursor env) => m (Id -> Maybe AnimId)
subId = Lens.view cursor <&> flip Id.subId

isSubCursor :: (MonadReader env m, HasCursor env) => m (Id -> Bool)
isSubCursor = subId <&> \sub prefix -> sub prefix & Lens.has Lens._Just

assignCursor ::
    (HasCursor env, MonadReader env m) =>
    Id -> Id -> m a -> m a
assignCursor src dest =
    Reader.local (cursor %~ replace)
    where
        replace c
            | c == src = dest
            | otherwise = c

assignCursorPrefix ::
    (HasCursor env, MonadReader env m) =>
    Id -> (AnimId -> Id) -> m a -> m a
assignCursorPrefix srcFolder dest =
    Reader.local (cursor %~ replace)
    where
        replace c =
            case Id.subId srcFolder c of
            Nothing -> c
            Just suffix -> dest suffix

-- TODO: Currently widget state is cleaned for widgets whose id isn't prefix of the cursor.
-- Consider allowing all widgets to store state which are cleaned when not access while generating root widget.
-- That would put more restrictions on the root widget monad.
class HasCursor env => HasState env where
    state :: Lens' env GUIState

instance HasState GUIState where state = id

readWidgetState ::
    (HasState env, MonadReader env m, Binary a) =>
    Id -> m (Maybe a)
readWidgetState wid =
    Lens.view (state . sWidgetStates . Lens.at wid) <&> (>>= f)
    where
        f x = decodeOrFail (BS.lazify x) ^? Lens._Right . _3

updateWidgetState :: Binary a => Id -> a -> Update
updateWidgetState wid val = mempty & uWidgetStateUpdates . Lens.at wid ?~ encodeS val
