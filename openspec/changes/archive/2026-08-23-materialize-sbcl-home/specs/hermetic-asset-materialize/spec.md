## ADDED Requirements

### Requirement: Container does not inherit host SBCL_HOME

When full-path materialize runs a language command in the materialize container, the program SHALL NOT pass the host process environment variables `SBCL_HOME` or `SBCL_SOURCE_ROOT` into the container. SBCL inside the container SHALL use the image-configured `SBCL_HOME` when SBCL is present. The program SHALL NOT bind-mount the operator’s `~/quicklisp` to satisfy this.

#### Scenario: Host SBCL_HOME is not forwarded

- **WHEN** full-path materialize `docker run`s a command and the host environment has `SBCL_HOME` set
- **THEN** the container invocation does not include `SBCL_HOME` from the host
- **AND** it does not include host `SBCL_SOURCE_ROOT`
