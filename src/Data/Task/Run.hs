module Data.Task.Run where


import Control.Monad.Ref
import Control.Monad.Trace
import Control.Monad.Writer

import Data.List (union, intersect)
import Data.Task
import Data.Task.Input



-- Observations ----------------------------------------------------------------


ui :: MonadRef l m => TaskT m a -> m (Doc b)
ui = \case
  Trans _ t    -> ui t

  Done _       -> pure "■(_)"
  Enter        -> pure "⊠(_)"
  Update v     -> pure $ sep [ "□(", pretty v, ")" ]
  View v       -> pure $ sep [ "⧇(", pretty v, ")" ]

  Pair t1 t2   -> pure (\l r -> sep [ l, " ⧓ ", r ]) <*> ui t1 <*> ui t2
  Choose t1 t2 -> pure (\l r -> sep [ l, " ◆ ", r ]) <*> ui t1 <*> ui t2
  Pick t1 t2   -> pure (\l r -> sep [ l, " ◇ ", r ]) <*> ui t1 <*> ui t2
  Fail         -> pure "↯"

  Bind t1 _    -> pure (<> " ▶…") <*> ui t1

  New v        -> pure $ sep [ "ref", pretty v ]
  Watch l      -> pure (\x   -> sep [ "⧈", pretty x ]) <*> deref l
  Change _ v   -> pure $ sep [ "⊟", pretty v ]


value :: MonadRef l m => TaskT m a -> m (Maybe a)
value = \case
  Trans f t    -> pure (map f) <*> value t

  Done v       -> pure (Just v)
  Enter        -> pure Nothing
  Update v     -> pure (Just v)
  View v       -> pure (Just v)

  Pair t1 t2   -> pure (<&>) <*> value t1 <*> value t2
  Choose t1 t2 -> pure (<|>) <*> value t1 <*> value t2
  Pick _ _     -> pure Nothing
  Fail         -> pure Nothing

  Bind _ _     -> pure Nothing

  New v        -> pure Just <*> ref v
  Watch l      -> pure Just <*> deref l
  Change _ _   -> pure (Just ())


failing :: TaskT m a -> Bool
failing = \case
  Trans _ t    -> failing t

  Done _       -> False
  Enter        -> False
  Update _     -> False
  View _       -> False

  Pair t1 t2   -> failing t1 && failing t2
  Choose t1 t2 -> failing t1 && failing t2
  Pick t1 t2   -> failing t1 && failing t2
  Fail         -> True

  Bind t _     -> failing t

  New _        -> False
  Watch _      -> False
  Change _ _   -> False


watching :: MonadRef l m => TaskT m a -> List (Someref m)
watching = \case
  Trans _ t    -> watching t

  Done _       -> []
  Enter        -> []
  Update _     -> []
  View _       -> []

  Pair t1 t2   -> watching t1 `union` watching t2
  Choose t1 t2 -> watching t1 `union` watching t2
  Pick _ _     -> []
  Fail         -> []

  Bind t _     -> watching t

  New _        -> []
  Watch l      -> [ pack l ]
  Change l _   -> [ pack l ]


choices :: TaskT m a -> List Path
choices = \case
  Pick Fail Fail -> []
  Pick _    Fail -> [ GoLeft ]
  Pick Fail _    -> [ GoRight ]
  Pick _    _    -> [ GoLeft, GoRight ]
  _              -> []


inputs :: forall m l a. MonadRef l m => TaskT m a -> m (List (Input Dummy))
inputs = \case
  Trans _ t    -> inputs t

  Done _       -> pure []
  Enter        -> pure [ ToHere (AChange tau) ]
  Update _     -> pure [ ToHere (AChange tau) ]
  View _       -> pure []

  Pair t1 t2   -> pure (\l r -> map ToFirst l <> map ToSecond r) <*> inputs t1 <*> inputs t2
  Choose t1 t2 -> pure (\l r -> map ToFirst l <> map ToSecond r) <*> inputs t1 <*> inputs t2
  Pick t1 t2   -> pure $ map (ToHere << APick) (choices $ Pick t1 t2)
  Fail         -> pure []

  Bind t _     -> inputs t

  New _        -> pure []
  Watch _      -> pure []
  Change _ _   -> pure [ ToHere (AChange tau) ]
  where
    tau = Proxy :: Proxy a



-- Striding --------------------------------------------------------------------


stride ::
  MonadRef l m =>
  TaskT m a -> WriterT (List (Someref m)) m (TaskT m a)
stride = \case
  -- * Step
  Bind t c -> do
    t' <- stride t
    vx <- lift $ value t'
    case vx of
      Nothing -> pure $ Bind t' c
      Just v  ->
        let t2 = c v in
        if failing t2
          then pure $ Bind t' c
          --NOTE: We return just the next task. Normalisation should handle the next stride.
          else pure t2
  -- * Choose
  Choose t1 t2 -> do
    t1' <- stride t1
    vx <- lift $ value t1'
    case vx of
      Just _  -> pure t1'
      Nothing -> do
        t2' <- stride t2
        vy <- lift $ value t2'
        case vy of
          Just _  -> pure t2'
          Nothing -> pure $ Choose t1' t2'
  -- * Evaluate
  Trans f t  -> pure (Trans f) <*> stride t
  Pair t1 t2 -> pure Pair <*> stride t1 <*> stride t2
  New v      -> pure $ ref v
  Watch l    -> pure $ deref l
  Change l v -> tell [ pack l ] *> pure (l <<- v)
  -- * Ready
  t@(Done _)   -> pure t
  t@(Enter)    -> pure t
  t@(Update _) -> pure t
  t@(View _)   -> pure t
  t@(Pick _ _) -> pure t
  t@(Fail)     -> pure t



-- Normalising -----------------------------------------------------------------


data Dirties m
  = Watched (List (Someref m))

instance Pretty (Dirties m) where
  pretty = \case
    Watched is -> sep [ "Found", pretty (length is), "dirty references" ]


normalise ::
  MonadRef l m => MonadTrace (Dirties m) m =>
  TaskT m a -> m (TaskT m a)
normalise t = do
  ( t', ds ) <- runWriterT (stride t)
  let ws = watching t'
  let is = ds `intersect` ws
  case is of
    [] -> pure t'
    _  -> trace (Watched is) $ normalise t'


initialise ::
  MonadRef l m => MonadTrace (Dirties m) m =>
  TaskT m a -> m (TaskT m a)
initialise = normalise



-- Handling --------------------------------------------------------------------


data NotApplicable
  = CouldNotChangeVal SomeTypeRep SomeTypeRep
  | CouldNotChangeRef SomeTypeRep SomeTypeRep
  -- | CouldNotFind Label
  -- | CouldNotContinue
  | CouldNotHandle (Input Action)


instance Pretty NotApplicable where
  pretty = \case
    CouldNotChangeVal v c -> sep [ "Could not change value because types", dquotes $ pretty v, "and", dquotes $ pretty c, "do not match" ]
    CouldNotChangeRef r c -> sep [ "Could not change value because cell", dquotes $ pretty r, "does not contain", dquotes $ pretty c ]
    -- CouldNotFind l   -> "Could not find label `" <> l <> "`"
    -- CouldNotContinue -> "Could not continue because there is no value to continue with"
    CouldNotHandle i -> sep [ "Could not handle input", dquotes $ pretty i ]


handle :: forall m l a.
  MonadRef l m => MonadTrace NotApplicable m =>
  TaskT m a -> Input Action -> m (TaskT m a)
handle t i_ = case ( t, i_ ) of
  -- * Edit
  ( Enter, ToHere (IChange v) )
    | Just Refl <- r ~~ typeOf v -> pure $ Update v
    | otherwise -> trace (CouldNotChangeVal (SomeTypeRep r) (someTypeOf v)) $ pure t
    where
      r = typeRep :: TypeRep a
  ( Update v, ToHere (IChange w) )
    -- NOTE: Here we check if `v` and `w` have the same type.
    -- If this is the case, it would be inhabited by `Refl :: a :~: b`, where `b` is the type of the value inside `Change`.
    | Just Refl <- v ~= w -> pure $ Update w
    | otherwise -> trace (CouldNotChangeVal (someTypeOf v) (someTypeOf w)) $ pure t
  ( Change l v, ToHere (IChange w) )
    -- NOTE: As in the `Update` case above, we check for type equality.
    | Just Refl <- v ~= w -> do
        l <<- w
        pure $ Change l w
    | otherwise -> trace (CouldNotChangeRef (someTypeOf l) (someTypeOf w)) $ pure t
  -- * Choosing
  ( Pick t1 _, ToHere (IPick GoLeft) ) ->
    if failing t1
      then pure t
      else pure t1
  ( Pick _ t2, ToHere (IPick GoRight) ) ->
    if failing t2
      then pure t
      else pure t2
  -- * Passing
  ( Bind t1 t2, i ) -> do
    t1' <- handle t1 i
    pure $ Bind t1' t2
  ( Trans f t1, i ) -> do
    t1' <- handle t1 i
    pure $ Trans f t1'
  ( Pair t1 t2, ToFirst i ) -> do
    t1' <- handle t1 i
    pure $ Pair t1' t2
  ( Pair t1 t2, ToSecond i ) -> do
    t2' <- handle t2 i
    pure $ Pair t1 t2'
  ( Choose t1 t2, ToFirst i ) -> do
    t1' <- handle t1 i
    pure $ Choose t1' t2
  ( Choose t1 t2, ToSecond i ) -> do
    t2' <- handle t2 i
    pure $ Choose t1 t2'
  -- * Rest
  _ ->
    trace (CouldNotHandle i_) $ pure t


interact ::
  MonadRef l m => MonadTrace NotApplicable m => MonadTrace (Dirties m) m =>
  TaskT m a -> Input Action -> m (TaskT m a)
interact t i =
  handle t i >>= normalise



-- Running ---------------------------------------------------------------------


getUserInput :: IO (Input Action)
getUserInput = do
  putText ">> "
  line <- getLine
  case line of
    "quit" -> exitSuccess
    _ -> case parse (words line) of
      Right input -> pure input
      Left message -> do
        print message
        getUserInput


loop :: Task a -> IO ()
loop task = do
  interface <- ui task
  print interface
  events <- inputs task
  print $ "Possibilities: " <> pretty events
  input <- getUserInput
  task' <- interact task input
  loop task'


run :: Task a -> IO ()
run task = do
  task' <- initialise task
  loop task'
