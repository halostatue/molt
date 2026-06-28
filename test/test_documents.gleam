pub const config = "# Project configuration
title = 'molt'
version = '1.0.0'
enabled = true # Do we need this?
max_retries = 3
rating = 4.5

# Inline table and inline array
owner = { name = \"Austin\", active = true }
project.tags = ['toml', \"parser\", 'gleam']

# Implicit table: `database` is never explicitly declared
[database.connection]
# Default host is localhost
host = 'localhost'
# Default port is the postgresql port
port = 5432
\"connection options\" = []

# Concrete table
[settings] # trailing comment on a table header
verbose = false
timeout = 30

[settings.debug]
level = 5

# Table array
[[plugins]]
name = 'formatter'
priority = 1

[[plugins]]
name = 'linter'
priority = 2
options = { strict = true, fix = false }

[[extensions]]

[app.'Microsoft Word'.options]
verbose = false
"

pub const simple_config = "[server]
hostname = \"localhost\"
port     = 8080
options  = {
  # Whether SSL is enabled
  ssl = {
    enabled = true,
    ciphers = ['TLSv1.2', 'TLSv1.3']
  }
}

[database]
url = \"postgres://\"
"
