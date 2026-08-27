// Package web — MySQL helpers and accounting Excel export.
package web

import (
	"context"
	"database/sql"
	"fmt"

	// MySQL driver: blank import registers the "mysql" driver.
	_ "github.com/go-sql-driver/mysql"
	"github.com/xuri/excelize/v2"
	"golang.org/x/crypto/bcrypt"
)

// openMySQL opens a MySQL connection. The caller must close it.
func openMySQL(dsn string) (*sql.DB, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(3)
	db.SetMaxIdleConns(1)
	return db, nil
}

// queryToRows executes a SELECT and returns (rows [][]any, colNames []string, err).
func queryToRows(ctx context.Context, db *sql.DB, query string) ([][]any, []string, error) {
	rows, err := db.QueryContext(ctx, query)
	if err != nil {
		return nil, nil, fmt.Errorf("query failed: %w", err)
	}
	defer rows.Close()

	cols, err := rows.Columns()
	if err != nil {
		return nil, nil, err
	}

	var result [][]any
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, nil, err
		}
		// Convert []byte (MySQL TEXT/BLOB/VARCHAR) to string for Excel compatibility.
		for i, v := range vals {
			if b, ok := v.([]byte); ok {
				vals[i] = string(b)
			}
		}
		result = append(result, vals)
	}
	return result, cols, rows.Err()
}

// buildAccountingExcel creates an Excel workbook with one sheet per accounting
// table found in the tenant's MySQL database.
func buildAccountingExcel(ctx context.Context, dsn, tenant string) (*excelize.File, error) {
	db, err := openMySQL(dsn)
	if err != nil {
		return nil, fmt.Errorf("connect to MySQL: %w", err)
	}
	defer db.Close()

	if err := db.PingContext(ctx); err != nil {
		return nil, fmt.Errorf("ping MySQL: %w", err)
	}

	f := excelize.NewFile()

	// Accounting table definitions — query + sheet name.
	// These match the actual Afrita backend MySQL schema.
	// Tables that don't exist (schema variance) are silently skipped.
	type sheetDef struct {
		name  string
		query string
	}
	sheets := []sheetDef{
		{
			name: "Chart of Accounts",
			query: `SELECT id, code, name, type, subtype, parent_id, is_active
			        FROM account ORDER BY code LIMIT 10000`,
		},
		{
			name: "Sales Invoices",
			query: `SELECT id, sequence_number, effective_date, payment_due_date,
			               client_id, userName, total_before_vat, total_vat, total,
			               discount_amount, amount_paid, payment_method, state, branch_id
			        FROM bill ORDER BY effective_date DESC LIMIT 10000`,
		},
		{
			name: "Purchase Bills",
			query: `SELECT id, sequence_number, supplier_sequence_number, effective_date,
			               payment_due_date, supplier_id, store_id, total_before_vat,
			               total_vat, total, discount, payment_method, state
			        FROM purchase_bill ORDER BY effective_date DESC LIMIT 10000`,
		},
		{
			name: "Journal Entries",
			query: `SELECT id, merchant_id, store_id, posted_at, source_type,
			               source_id, description, created_by, created_at
			        FROM journal_entry ORDER BY posted_at DESC LIMIT 10000`,
		},
		{
			name: "Journal Lines",
			query: `SELECT id, entry_id, account_id, debit, credit
			        FROM journal_line ORDER BY entry_id DESC, id DESC LIMIT 10000`,
		},
		{
			name: "Sales Payments",
			query: `SELECT id, bill_id, date, paid_at, amount, currency_id,
			               payment_method, recorded_by, note, created_at
			        FROM bill_payment ORDER BY paid_at DESC LIMIT 10000`,
		},
		{
			name: "Purchase Payments",
			query: `SELECT id, purchase_bill_id, date, paid_at, amount, currency_id,
			               payment_method, product_id, recorded_by, note, created_at
			        FROM purchase_bill_payment ORDER BY paid_at DESC LIMIT 10000`,
		},
		{
			name: "Expenses",
			query: `SELECT id, merchant_id, store_id, category_id, amount,
			               vat_amount, spent_at, note, created_by, created_at
			        FROM expense ORDER BY spent_at DESC, id DESC LIMIT 10000`,
		},
		{
			name: "Credit Notes",
			query: `SELECT id, bill_id, state, NOTE AS note, created_at,
			               invoice_uuid, invoice_hash, invoice_xml_path
			        FROM credit_note ORDER BY created_at DESC, id DESC LIMIT 10000`,
		},
		{
			name: "Cash Vouchers",
			query: `SELECT id, voucher_number, voucher_type, effective_date, amount,
			               payment_method, state, reference_type, reference_id,
			               recipient_type, recipient_id, recipient_name, description,
			               note, bank_name, bank_account, transaction_reference,
			               store_id, merchant_id, branch_id, created_by, approved_by,
			               approved_at, created_at, updated_at
			        FROM cash_voucher ORDER BY effective_date DESC, id DESC LIMIT 10000`,
		},
	}

	// Header style: bold, light-blue fill
	headerStyle, _ := f.NewStyle(&excelize.Style{
		Font: &excelize.Font{Bold: true, Color: "1A1A2E"},
		Fill: excelize.Fill{
			Type:    "pattern",
			Color:   []string{"#D6E4F0"},
			Pattern: 1,
		},
		Border: []excelize.Border{
			{Type: "bottom", Color: "2F80C0", Style: 2},
		},
	})

	firstSheet := true
	populated := 0

	for _, sh := range sheets {
		rows, cols, err := queryToRows(ctx, db, sh.query)
		if err != nil {
			// Table may not exist in this tenant's schema — skip silently.
			continue
		}

		var sheetName string
		if firstSheet {
			// excelize creates "Sheet1" by default; rename it.
			f.SetSheetName("Sheet1", sh.name)
			sheetName = sh.name
			firstSheet = false
		} else {
			sheetName = sh.name
			_, _ = f.NewSheet(sheetName)
		}

		// Write column headers in row 1
		endCell, _ := excelize.CoordinatesToCellName(len(cols), 1)
		for ci, col := range cols {
			cell, _ := excelize.CoordinatesToCellName(ci+1, 1)
			_ = f.SetCellValue(sheetName, cell, col)
		}
		_ = f.SetCellStyle(sheetName, "A1", endCell, headerStyle)
		_ = f.SetRowHeight(sheetName, 1, 18)

		// Write data rows starting at row 2
		for ri, row := range rows {
			for ci, val := range row {
				cell, _ := excelize.CoordinatesToCellName(ci+1, ri+2)
				_ = f.SetCellValue(sheetName, cell, val)
			}
		}

		// Auto-fit columns (approximate: set width based on header length)
		for ci, col := range cols {
			colName, _ := excelize.ColumnNumberToName(ci + 1)
			width := float64(len(col) + 4)
			if width < 10 {
				width = 10
			}
			if width > 40 {
				width = 40
			}
			_ = f.SetColWidth(sheetName, colName, colName, width)
		}

		// Freeze the header row
		_ = f.SetPanes(sheetName, &excelize.Panes{
			Freeze:      true,
			YSplit:      1,
			TopLeftCell: "A2",
			ActivePane:  "bottomLeft",
		})

		populated++
	}

	if firstSheet {
		// No accounting tables found — provide an informative sheet.
		f.SetSheetName("Sheet1", "No Data")
		_ = f.SetCellValue("No Data", "A1", fmt.Sprintf(
			"No accounting tables found for tenant: %s. "+
				"The database may be empty or use a different schema.", tenant))
	} else if populated > 0 {
		// Add a summary sheet
		summaryName := "Summary"
		_, _ = f.NewSheet(summaryName)
		_ = f.SetCellValue(summaryName, "A1", "Afrita Accounting Export")
		_ = f.SetCellValue(summaryName, "A2", fmt.Sprintf("Tenant: %s", tenant))
		_ = f.SetCellValue(summaryName, "A3", fmt.Sprintf("Sheets: %d", populated))
		_ = f.SetCellValue(summaryName, "A4", "Data is limited to 10,000 rows per sheet.")
	}

	return f, nil
}

// updateUserPasswordMySQL updates a user's bcrypt password hash directly in MySQL.
// The backend uses bcrypt (cost 10) for passwords.
func updateUserPasswordMySQL(ctx context.Context, dsn, username, newPassword string) error {
	if username == "" {
		return fmt.Errorf("username is empty")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(newPassword), 10)
	if err != nil {
		return fmt.Errorf("bcrypt hash: %w", err)
	}

	db, err := openMySQL(dsn)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer db.Close()

	if err := db.PingContext(ctx); err != nil {
		return fmt.Errorf("ping: %w", err)
	}

	res, err := db.ExecContext(ctx,
		"UPDATE `user` SET password = ? WHERE username = ?",
		string(hash), username,
	)
	if err != nil {
		return fmt.Errorf("update: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("user %q not found in database", username)
	}
	return nil
}
