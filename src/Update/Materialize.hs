-- | Materialize-image ensure: floors, sidecar, generated Dockerfile, IO.
--
-- Product surface for the executable, spine, and tests. Implementation lives
-- in @Update.Materialize.*@ other-modules.
module Update.Materialize
  ( module Update.Materialize.Floors,
    module Update.Materialize.Sidecar,
    module Update.Materialize.Resolve,
    module Update.Materialize.Recipe,
    module Update.Materialize.Ensure,
  )
where

import Update.Materialize.Ensure
import Update.Materialize.Floors
import Update.Materialize.Recipe
import Update.Materialize.Resolve
import Update.Materialize.Sidecar
