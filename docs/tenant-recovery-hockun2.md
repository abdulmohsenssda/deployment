# Recover the `hockun2` dev tenant after the v0.0.1 drift

`hockun2.dev.ifritah.com` shipped with a mismatched backend + frontend
image pair. Both apps were tagged `:v0.0.1` on Docker Hub but the images
were built at different points in time:

| Image | Built from | Missing on the deployed image |
|-------|-----------|--------------------------------|
| `ifritah-api:v0.0.1`  | pre-`ifritah-go#50`  | `/api/v2/purchase_bill/duplicate-check` endpoint |
| `ifritah-web:v0.0.1`  | post-`go_ifritah#50` | (has the pre-check UI that calls the endpoint above) |

Playwright reproduction against `hockun2` confirmed:

- `POST /api/purchase-bills/duplicate-check → 404` (frontend proxy forwards
  the backend 404 verbatim, which triggers the yellow "تعذر التحقق من التكرار"
  banner in the Add Purchase Bill form).
- `POST /api/purchase-bills → 200` (the actual create endpoint is on both
  images, so bills can still be created if the user attaches a PDF and hits
  Save through the yellow banner).

## Second-order regression: schema drift on the tenant DB

When hockun2 was upgraded from `:v0.0.1` to `:v0.0.2` via `update-tenant.sh`,
the container was swapped onto a backend that expects columns added by
`pkg/db/migrations/0005_purchase_bill_product_item_fields.sql`
(`cost_price`, `shelf_number` on `purchase_bill_product`, introduced by
`ifritah-go#53` on 2026-07-15). The tenant DB was last migrated when the
tenant was **created** (pre-#53), so those columns were missing. Every
`INSERT INTO purchase_bill_product` therefore failed with `Error 1054
Unknown column 'cost_price'`, which the backend surfaces as
`c.Status(http.StatusBadRequest)` with an empty body — the frontend proxy
renders the fallback toast `"فشل في إنشاء فاتورة الشراء"`. Same table
breaks the read path (`GET /dashboard/purchase-bills/<id>` returns 500 out
of `GetPurchaseBillProducts`).

`update-tenant.sh` was extended (see this repo's fix) to re-apply the
`pkg/db/migrations/*.sql` bundle from the incoming backend image
automatically before swapping the container. Every migration is idempotent
(each `ALTER` guarded by `information_schema.columns`), so re-applying the
full set on already-migrated tenants is a no-op.

## Fix (short version)

The scary banner and the "Save does nothing without PDF" silence are
addressed by `go_ifritah#72`. The image-drift itself is prevented going
forward by:

- `ifritah-go#70` — backend deploy workflow now publishes a `:dev` alias.
- `go_ifritah` deploy workflow already publishes a `:dev` alias.
- `scripts/update-tenant.sh` in this repo now preflights backend + frontend
  `org.opencontainers.image.version` labels and refuses to deploy a
  mismatched pair.
- `scripts/update-tenant.sh` in this repo now re-applies the backend
  image's schema migrations before every image swap, so a tenant DB frozen
  at an older schema is fixed up automatically instead of silently 400-ing.

## Steps to recover the currently-broken `hockun2` tenant

1. Confirm the new `v0.0.2` images are on Docker Hub (both should carry the
   `org.opencontainers.image.version=v0.0.2` label from their build workflow):

   ```bash
   docker pull "${DOCKERHUB_USERNAME}/ifritah-api:v0.0.2"
   docker pull "${DOCKERHUB_USERNAME}/ifritah-web:v0.0.2"

   docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' \
       "${DOCKERHUB_USERNAME}/ifritah-api:v0.0.2"
   docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' \
       "${DOCKERHUB_USERNAME}/ifritah-web:v0.0.2"
   # Both must print: v0.0.2
   ```

2. Re-run `update-tenant.sh` on hockun2. The drift preflight will refuse
   to deploy if the labels disagree, and the migration replay will run
   automatically before the container swap:

   ```bash
   sudo ./scripts/update-tenant.sh hockun2 \
       --backend-image  "${DOCKERHUB_USERNAME}/ifritah-api:v0.0.2" \
       --frontend-image "${DOCKERHUB_USERNAME}/ifritah-web:v0.0.2" \
       --restart
   ```

   Expected on success:

   ```
   [+] Pulling image: .../ifritah-api:v0.0.2
   [+] Pulling image: .../ifritah-web:v0.0.2
   [+] Image versions match: v0.0.2 (backend + frontend)
   [+] Applying schema/migrations from .../ifritah-api:v0.0.2 (idempotent)
       ... init-tenant-db.sh --schema-only output ...
   [+] Deploying backend:  .../ifritah-api:v0.0.2
   [+] Deploying frontend: .../ifritah-web:v0.0.2
   [+] Restarting tenant...
   ```

## Emergency manual migration (if `update-tenant.sh` is not available)

If you need to unblock the tenant RIGHT NOW without re-running the full
update flow — e.g. the tenant is already on the new image but its DB was
never migrated — apply the missing columns directly:

```bash
./scripts/init-tenant-db.sh hockun2 \
    --schema-only \
    --backend-image "${DOCKERHUB_USERNAME}/ifritah-api:v0.0.2"
```

Or, if the operator has direct MySQL access and just needs the two
`purchase_bill_product` columns from migration 0005:

```sql
SET @s := IF(
  (SELECT COUNT(*) FROM information_schema.columns
   WHERE table_schema = DATABASE()
     AND table_name = 'purchase_bill_product'
     AND column_name = 'cost_price') = 0,
  'ALTER TABLE `purchase_bill_product` ADD COLUMN `cost_price` DECIMAL(12,2) NOT NULL DEFAULT 0.00 AFTER `price`',
  'SELECT 1'
);
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(
  (SELECT COUNT(*) FROM information_schema.columns
   WHERE table_schema = DATABASE()
     AND table_name = 'purchase_bill_product'
     AND column_name = 'shelf_number') = 0,
  'ALTER TABLE `purchase_bill_product` ADD COLUMN `shelf_number` VARCHAR(45) NULL AFTER `name`',
  'SELECT 1'
);
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
```

This information-schema guard is intentionally used instead of
`ADD COLUMN IF NOT EXISTS`, which is not available on the older MySQL
versions used by some tenants. It is safe to apply repeatedly.

## Smoke tests after recovery

Log in to `https://hockun2.dev.ifritah.com/` as `admin / Qwerty123` and:

1. `POST /api/purchase-bills/duplicate-check`  
   body `{"supplier_id": <existing supplier id>, "supplier_sequence_number": 1}`  
   → 200 `{"exists": false}`

2. On `/dashboard/products/add`:
   - Field is `اسم القطعة` free-text input (not the old `رقم القطعة OEM` widget).
   - Typing a free-form name and saving creates the product.

3. On `/dashboard/purchase-bills/add`:
   - No yellow "تعذر التحقق من التكرار" banner.
   - Clicking Save without a PDF renders a visible red "يرجى رفع ملف فاتورة الشراء (PDF)" error and scrolls to the PDF slot.
   - Attaching a PDF and clicking Save creates the bill and navigates to the list page with a success toast.

4. On `/dashboard/purchase-bills/<any existing bill id>`:
   - Detail page renders (was 500ing during the schema-drift window because
     `GetPurchaseBillProducts` referenced the missing columns).

## Optional cleanup

The reproduction run left one test supplier (`مورد اختبار`, id 253) and two
purchase bills (`630264` and `7490047`) in the tenant DB. They are labelled
"مضاف يدوياً" and can stay for regression-testing the drift preflight later,
or be soft-deleted through the UI if the tenant is being handed to real
users.

## Preventing recurrence

Any future tenant deploy via `update-tenant.sh` will:

- Reconcile the tenant frontend domain, `APP_DOMAIN`, and `API_URL` with the
  current `BASE_DOMAIN` before pulling images or running migrations. A failed
  image/migration step cannot preserve the old public URL.
- Pull both images.
- Read `org.opencontainers.image.version` from each.
- Abort with a clear error message if the labels disagree, before swapping
  either app to a mismatched image.
- Re-apply every migration bundled in the backend image (idempotent), so a
  tenant DB that lags the current schema is auto-repaired before the new
  container is swapped in.

Both checks can be bypassed (`--skip-drift-check`, `--skip-migrations`) for
targeted rollback investigations, but both bypasses are loud (warning
banners on stdout and stderr).

## If `BASE_DOMAIN` changed

`BASE_DOMAIN` controls new tenant values, while Dokku keeps old domains/config
persisted. Tenant **Sync**, **Rebuild**, and fleet sync now reconcile existing
tenants before deployment. Repair one tenant without changing its images with:

```bash
sudo ./scripts/update-tenant.sh hockun2 --routing-only --config /opt/deployment/config.env
```

Repair every tenant with:

```bash
sudo ./scripts/post-merge-cleanup.sh
```

Verify the frontend owns the new hostname and has the matching `API_URL`:

```bash
docker exec dokku dokku domains:report hockun2-frontend
docker exec dokku dokku config:show hockun2-frontend | grep -E '^(APP_DOMAIN|API_URL)='
```
