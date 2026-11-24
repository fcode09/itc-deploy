# Environment variables: the schema

Every instance has up to three files of variables: `.env.instance` (what the instance is: name, services, tags, ports) and one
`.env.<sN>` per service (what the service reads). `lib/core/envschema.sh` knows what each variable is, so the CLI and the panel
validate, describe and mask them the same way.

## Where the table comes from

Nothing is written twice:

| Source | Gives |
| --- | --- |
| `lib/help/variables.txt` (and `lib/help/en/variables.txt`) | key, file, type (`obligatoria`/`required`, `opcional`/`optional`, `fija`/`fixed`), default value and description |
| `templates/.env.*.example` | the example value of each key; the keys of a service the glossary does not know yet |
| `lib/core/catalog.data` | which variables are required (`REQUIRED_<SN>`) and which ones the tool can generate (`--generate-secrets`) |
| `lib/core/envschema.data` | the validator of each key and whether it is a secret, by rules on the name |

A variable is identified by `<file>|<KEY>` (`.env.s1|JWT_SECRET`): the same key can be in two files.

**To add a variable:** add its entry to the glossary (both languages) and to the template, as `tests/test-help.sh` already asks.
It shows up in the schema by itself, with the validator and the secret flag its name suggests (`*_PORT` is a port, `*_SECRET` and
`*_API_KEY` are secrets, `*_ENABLED` is true/false…). Add a line to `envschema.data` only when the name is not enough.

## `envschema.data`

One rule per line, `pattern|validator|secret`; the first rule that matches wins. The pattern is a glob on the key, or
`<file>:<glob>` to limit it to one file. The last rule (`*|text|0`) catches everything else.

## Validators

A validator leaves `EV_RC` (0 valid, 1 invalid, 2 valid but with a warning) and `EV_MSG` (in the active language).
**No message repeats the value**: a secret must not reach a screen or a log through an error text.

| Validator | Accepts |
| --- | --- |
| `port` | 1 to 65535 |
| `int`, `bool` | digits; `true` or `false` |
| `mongo-uri` | `mongodb://` or `mongodb+srv://`, with credentials and several hosts; warns when a host is `localhost`, `127.x` or `::1` (inside a container that is the container itself) |
| `public-url` | `http(s)://host`, no path or trailing slash; a port only warns; `${VAR}` references |
| `url`, `url-ws` | `http(s)://…` without trailing slash; `url-ws` also takes `ws://` and `wss://` |
| `b64-32` | base64 of exactly 32 bytes (`openssl rand -base64 32`) |
| `secret-path` | `/run/secrets/<file>`: the PATH, never the content |
| `secret-min32` | 32 characters or more, no spaces |
| `memory` | `512m`, `2g`, `1.5g`, `1024`… (not zero) |
| `tag` | a tag; `latest` warns |
| `image-name`, `instance-name`, `registry`, `host`, `duration`, `json-line`, `path`, `services-list`, `text` | see `ev_<name>` in `envschema.sh` |

An empty value is an error for a required variable and fine for an optional one. A `fixed` variable (set by the compose or the image)
does not go in the file. A value with a line break never validates.

## Reading it

```bash
source lib/bootstrap.sh
envschema_load                                   # once per language
envschema_check_r .env.instance S0_PORT abc      # EV_RC=1, EV_MSG="must be a port…"
envschema_generator .env.s0 JWT_SECRET           # shared  (hex32, hex24, b64-32 or nothing)
for id in "${ENV_IDS[@]}"; do echo "${ENV_FILE[$id]} ${ENV_KEY[$id]} ${ENV_TYPE[$id]} ${ENV_VALIDATOR[$id]}"; done
```

The arrays are `ENV_KEY`, `ENV_FILE`, `ENV_TYPE` (`req`, `opt`, `fixed`), `ENV_DEFAULT` with `ENV_HASDEF` (a default that is only a
description, such as "none" or "disabled", is in `ENV_DEFNOTE` and is never offered as a value), `ENV_DESC`, `ENV_VALIDATOR`,
`ENV_SECRET`, `ENV_GEN`, `ENV_REQUIRED` and `ENV_EXAMPLE`. Reading it starts no process.

## Changing them: `./deltactl env`

`env <instance> list|get|set|generate|pending` (page: `./deltactl help env`) is the CLI over `lib/core/envedit.sh`; the panel uses the same
functions, so both write the same way.

| What | How it works |
| --- | --- |
| Validation | `envedit_save` checks the value with the schema first; an invalid one writes nothing. A warning (a Mongo URI on `localhost`) saves and shows the message. `--force` writes an invalid value or a key the glossary does not know, never a `fixed` variable or a value with a line break |
| Writing | The file is rebuilt in a temporary file next to it and renamed over it, so a failure halfway leaves the old file as it was. Comments, blank lines and the order stay; a value is kept byte by byte (`=`, quotes, spaces, `\`, `%`, empty, CRLF). It is done without `awk`: `awk -v` would read `\n` and `\\` of a value as escapes |
| Copy | `<file>.bak` (same mode) before the first change of the session (the process); the second change does not overwrite it |
| Mode | A file that gets a secret is left in mode 600; a new file is born 600 |
| Secrets | `list` and `get` mask them (`********`); `--reveal` shows them. A value comes from the command line, `--stdin` or, for a secret with no value, a hidden prompt. None of these operations is recorded in `runs`: the value would be in its command line. The messages never repeat a value |
| Generating | `envedit_generate`: `hex32`, `hex24` and `b64-32` with `openssl rand`; a `shared` one (`JWT_SECRET`) gets the same value in every service file that has it. It asks before replacing a value (`--yes` skips it) and warns of the consequence: sessions closed, or what was encrypted with the old key unreadable |
| Pending changes | When a deploy ends well, `.deployed` gets `ENV_SUM_<FILE>` (the sum of each env file it used; `.env.instance` only when the whole instance was deployed). `env pending` and `list` compare against it. A file with no mark (deployed before this existed) is `unknown`: nothing is said about it. A secret never reaches `.deployed`, only a sum |

State of a variable (`envedit_state_r`): `ok`, `warn` (valid with a warning), `invalid`, `missing` (required and empty), `example` (still has the
`CAMBIAR…` of the template: `deploy` refuses it too), `default` (empty, but the glossary has a default), `unset` and `fixed`.
