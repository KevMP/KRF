--!strict
-- Private defaults, independent of package semver. Tests use these bounds rather
-- than promising their numeric values as consumer API.
return table.freeze({ PROTOCOL_VERSION = 1, MAX_BOOTSTRAP_BYTES = 65536, INIT_TIMEOUT_SECONDS = 10 })
