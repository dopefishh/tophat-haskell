module Data.Task
  ( Task(..), Ref
  , (<?>), (>>?), forever, change
  , module Control.Interactive
  , module Control.Collaborative
  , module Data.Editable
  ) where


import Control.Interactive
import Control.Collaborative

import Data.Editable (Editable)


-- Tasks -----------------------------------------------------------------------

-- | Task monad transformer build on top of a monad `m`.
-- |
-- | To use references, `m` shoud be a `Collaborative` with locations `r`.
data Task (m :: Type -> Type) (t :: Type) where
  -- * Editors
  -- | Internal, unrestricted and hidden editor
  Done :: t -> Task m t
  -- | Unvalued editor
  Enter :: ( Editable t ) => Task m t
  -- | Valued editor
  Update :: ( Editable t ) => t -> Task m t
  -- | Valued, view only editor
  View :: ( Editable t ) => t -> Task m t
  -- | External choice between two tasks.
  Pick :: Dict Label (Task m t) -> Task m t

  -- * Parallels
  -- | Composition of two tasks.
  Pair :: Task m a -> Task m b -> Task m ( a, b )
  -- | Internal choice between two tasks.
  Choose :: Task m t -> Task m t -> Task m t
  -- | The failing task
  Fail :: Task m t

  -- * Transform
  -- | Internal value transformation
  Trans :: (a -> t) -> Task m a -> Task m t

  -- * Step
  -- | Internal, or system step.
  Step :: Task m a -> (a -> Task m t) -> Task m t

  -- * Loops
  -- | Repeat a task indefinitely
  Forever :: Task m t -> Task m Void

  -- * References
  -- The inner monad `m` needs to have the notion of references.
  -- These references should be `Eq` and `Typeable`,
  -- because we need to mark them dirty and match those with watched references.
  -- | Create new reference of type `t`
  Share :: ( Collaborative r m, Editable t ) => t -> Task m (Store r t t)
  -- | Assign to a reference of type `t` to a given value
  Assign :: ( Collaborative r m, Editable s, Editable a ) => a -> Store r s a -> Task m ()
  -- | Change to a reference of type `t` to a value
  Change :: ( Collaborative r m, Editable s, Editable t ) => Store r s t -> Task m t
  -- | Watch a reference of type `t`
  Watch :: ( Collaborative r m, Editable s, Editable t ) => Store r s t -> Task m t


type Ref = IORef

-- Instances -------------------------------------------------------------------

infixl 3 <?>
infixl 1 >>?

(<?>) :: Task m a -> Task m a -> Task m a
(<?>) t1 t2 = pick [ ( "Left", t1 ), ( "Right", t2 ) ]

(>>?) :: Task m a -> (a -> Task m b) -> Task m b
(>>?) t c = t >>= \x -> pick [ ( "Continue", c x ) ]

forever :: Task m a -> Task m Void
forever = Forever

instance Pretty (Task m t) where
  pretty = \case
    Done _       -> "Done _"
    Enter        -> "Enter"
    Update v     -> parens <| sep [ "Update", pretty v ]
    View v       -> parens <| sep [ "View", pretty v ]
    Pick ts      -> parens <| sep [ "Pick", pretty ts ]

    Pair t1 t2   -> parens <| sep [ pretty t1, "<&>", pretty t2 ]
    Choose t1 t2 -> parens <| sep [ pretty t1, "<|>", pretty t2 ]
    Fail         -> "Fail"

    Trans _ t    -> sep [ "Trans _", pretty t ]
    Step t _     -> parens <| sep [ pretty t, ">>=", "_" ]
    Forever t    -> sep [ "Forever", pretty t ]

    Share v      -> sep [ "Share", pretty v ]
    Assign v _   -> sep [ "_", ":=", pretty v ]
    Watch _      -> sep [ "Watch", "_" ]
    Change _     -> sep [ "Change", "_" ]

instance Functor (Task m) where
  fmap = Trans

instance Interactive (Task m) where
  enter  = Enter
  update = Update
  view   = View
  pick   = Pick

instance Monoidal (Task m) where
  (<&>) = Pair
  skip  = Done ()

instance Applicative (Task m) where
  pure  = Done
  (<*>) = applyDefault

instance Selective (Task m) where
  branch p t1 t2 = go =<< p
    where
      go (Left  a) = map (<| a) t1
      go (Right b) = map (<| b) t2

instance Alternative (Task m) where
  (<|>) = Choose
  empty = Fail

instance Monad (Task m) where
  (>>=) = Step

instance Collaborative r m => Collaborative r (Task m) where
  share  = Share
  assign = Assign
  watch  = Watch

change :: ( Collaborative r m, Editable s, Editable t ) => Store r s t -> Task m t
change = Change
