# Example Configurations

Working examples of NMIS9 model and override configurations. These
files are documentation -- they are NOT loaded by NMIS at runtime.
To activate any of them, copy into the operator-owned location
described in each example's header comment (typically
`models-custom/` or `conf/`).

## Contents

- **`Override-Model-net-snmp-mongodb.nmis`** -- pattern for layering
  a Common file (`Common-Linux-HTTP-MongoDB.nmis`) onto a stock
  model (`Model-net-snmp.nmis`) on specific nodes. Demonstrates the
  `_apply_scoped_override` mechanism, additive hash merge for
  `class`, and the manual restate-and-append pattern for string
  fields like `nodegraph` and `systemHealth.sections`. See
  `docs/Model-Reference.md`, section 19, "Wiring a Common file into
  an existing model on a single node".
