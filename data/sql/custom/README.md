This folder should contains only re-applicable sql

e.g:

- CREATE IF NOT EXISTS
- REPLACE INTO
- DELETE + INSERT
- UPDATES with fixed values

etc.

## How to Apply Changes

To apply changes made to files in this directory, you must rebuild the DB import container:

```bash
docker compose up --build ac-db-import && docker compose restart ac-authserver
```
