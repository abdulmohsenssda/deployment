package config

import "testing"

func TestMySQLAdminCredentialsPreferCanonicalNames(t *testing.T) {
	t.Setenv("MYSQL_ADMIN_USER", "deployment_user")
	t.Setenv("MYSQL_ADMIN_PASSWORD", "deployment_password")
	t.Setenv("MYSQL_ROOT_USER", "legacy_user")
	t.Setenv("MYSQL_ROOT_PASSWORD", "legacy_password")

	if got := mysqlAdminUser(); got != "deployment_user" {
		t.Fatalf("mysqlAdminUser() = %q, want deployment_user", got)
	}
	if got := mysqlAdminPassword(); got != "deployment_password" {
		t.Fatalf("mysqlAdminPassword() = %q, want deployment_password", got)
	}
}

func TestMySQLAdminCredentialsUseLegacyFallback(t *testing.T) {
	t.Setenv("MYSQL_ADMIN_USER", "")
	t.Setenv("MYSQL_ADMIN_PASSWORD", "")
	t.Setenv("MYSQL_ROOT_USER", "legacy_user")
	t.Setenv("MYSQL_ROOT_PASSWORD", "legacy_password")

	if got := mysqlAdminUser(); got != "legacy_user" {
		t.Fatalf("mysqlAdminUser() = %q, want legacy_user", got)
	}
	if got := mysqlAdminPassword(); got != "legacy_password" {
		t.Fatalf("mysqlAdminPassword() = %q, want legacy_password", got)
	}
}

func TestMySQLAdminUserDefaultsToDeploymentAccount(t *testing.T) {
	t.Setenv("MYSQL_ADMIN_USER", "")
	t.Setenv("MYSQL_ROOT_USER", "")
	t.Setenv("MYSQL_ADMIN_PASSWORD", "")
	t.Setenv("MYSQL_ROOT_PASSWORD", "")

	if got := mysqlAdminUser(); got != "dokku_admin" {
		t.Fatalf("mysqlAdminUser() = %q, want dokku_admin", got)
	}
}

func TestMySQLAdminUserPreservesPasswordOnlyLegacyRootConfig(t *testing.T) {
	t.Setenv("MYSQL_ADMIN_USER", "")
	t.Setenv("MYSQL_ADMIN_PASSWORD", "")
	t.Setenv("MYSQL_ROOT_USER", "")
	t.Setenv("MYSQL_ROOT_PASSWORD", "legacy_password")

	if got := mysqlAdminUser(); got != "root" {
		t.Fatalf("mysqlAdminUser() = %q, want root", got)
	}
	if got := mysqlAdminPassword(); got != "legacy_password" {
		t.Fatalf("mysqlAdminPassword() = %q, want legacy_password", got)
	}
}
