"use client";

import { useCallback, useMemo, useState } from "react";
import { Schema } from "effect";
import {
  CodeStorageAccountsResponseSchema,
  type CodeStorageAccountEntry,
} from "@shared/agent/code-storage-account-contract";
import {
  Alert,
  Button,
  FormField,
  Input,
  RefreshIconButton,
  Textarea,
  UiModal,
  UiModalBody,
  UiModalHeader,
} from "@/ui";
import { Eye, EyeOff, KeyRound, Plus, X } from "@/ui/icon-registry";
import { ResourceLogo } from "@/ui/resource-logo";
import { useMountSubscription } from "@/hooks/use-mount-subscription";
import {
  DataRow,
  EndCell,
  HeadCell,
  IdentityCell,
  RowAction,
  StatusText,
  TableFrame,
  TableNotice,
  TableSection,
  TableSkeleton,
  TextCell,
} from "@/features/recipes/recipes-content/catalog-table-shell";
import { requestJson } from "./google-account-model";

const ACCOUNT_URL = "/api/agent/accounts/code-storage";
const decodeAccounts = Schema.decodeUnknownSync(CodeStorageAccountsResponseSchema);
const ACCOUNT_COLUMNS = ["Account", "Organization", "State"] as const;
const ACCOUNT_MIN_WIDTH = "min-w-[34rem]";

function CodeStorageAccountModal({
  onClose,
  onChanged,
}: {
  onClose: () => void;
  onChanged: (accounts: readonly CodeStorageAccountEntry[]) => void;
}) {
  const [organization, setOrganization] = useState("");
  const [label, setLabel] = useState("");
  const [privateKey, setPrivateKey] = useState("");
  const [showKey, setShowKey] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const connect = async () => {
    setBusy(true);
    setError("");
    try {
      const result = await requestJson(ACCOUNT_URL, decodeAccounts, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          organization,
          label: label.trim() || undefined,
          privateKey,
        }),
      });
      setPrivateKey("");
      onChanged(result.accounts);
      onClose();
    } catch (connectError) {
      setError(connectError instanceof Error ? connectError.message : "Connection failed");
    } finally {
      setBusy(false);
    }
  };

  const valid = organization.trim().length > 0 && privateKey.trim().length > 0;

  return (
    <UiModal isOpen onClose={busy ? () => undefined : onClose} maxWidth="max-w-lg">
      <UiModalHeader
        title="Connect Code.Storage"
        icon={
          <span className="flex h-8 w-8 items-center justify-center rounded-lg border border-(--ui-info)/30 bg-(--ui-info)/10">
            <KeyRound className="h-4 w-4 text-(--ui-info)" />
          </span>
        }
        onClose={onClose}
        showCloseButton={!busy}
        closeIcon={<X className="h-4 w-4" />}
      />
      <UiModalBody className="space-y-4 pb-5">
        <Alert variant="info">
          The private key is stored through the credential store selected in Settings. Agents
          receive short-lived, repository-scoped credentials and never receive the private key.
        </Alert>
        {error ? <Alert variant="error">{error}</Alert> : null}
        <FormField
          label="Organization"
          description="The lowercase organization from your-org.code.storage."
        >
          <Input
            value={organization}
            onChange={(event) => setOrganization(event.target.value.toLowerCase().trim())}
            placeholder="your-org"
            autoComplete="off"
          />
        </FormField>
        <FormField label="Label" description="Optional name for distinguishing several accounts.">
          <Input
            value={label}
            onChange={(event) => setLabel(event.target.value)}
            placeholder="Work account"
            autoComplete="off"
          />
        </FormField>
        <FormField
          label="Private key"
          description="Paste the PKCS8 P-256 PEM generated for this organization."
        >
          <div className="relative">
            <Textarea
              value={privateKey}
              onChange={(event) => setPrivateKey(event.target.value)}
              placeholder="-----BEGIN PRIVATE KEY-----"
              autoComplete="off"
              spellCheck={false}
              className={`min-h-36 pr-10 font-mono ${showKey ? "" : "[-webkit-text-security:disc]"}`}
            />
            <button
              type="button"
              onClick={() => setShowKey((current) => !current)}
              className="absolute right-2 top-2 rounded p-1 text-(--ui-muted) hover:bg-(--ui-hover) hover:text-(--ui-fg)"
              aria-label={showKey ? "Hide private key" : "Show private key"}
            >
              {showKey ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
            </button>
          </div>
        </FormField>
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
          <Button onClick={() => void connect()} loading={busy} disabled={!valid}>
            Connect account
          </Button>
        </div>
      </UiModalBody>
    </UiModal>
  );
}

export function CodeStorageAccountsSection({ searchQuery = "" }: { searchQuery?: string } = {}) {
  const [accounts, setAccounts] = useState<readonly CodeStorageAccountEntry[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [open, setOpen] = useState(false);
  const [disconnecting, setDisconnecting] = useState<string | null>(null);
  const [busyAccount, setBusyAccount] = useState<string | null>(null);
  const [error, setError] = useState("");

  const refresh = useCallback(() => {
    setRefreshing(true);
    void requestJson(ACCOUNT_URL, decodeAccounts, { cache: "no-store" })
      .then((result) => {
        setAccounts(result.accounts);
        setError("");
      })
      .catch((loadError: unknown) => {
        setError(loadError instanceof Error ? loadError.message : "Code.Storage accounts failed");
      })
      .finally(() => {
        setLoaded(true);
        setRefreshing(false);
      });
  }, []);

  useMountSubscription(() => {
    refresh();
  }, [refresh]);

  const disconnect = async (accountId: string) => {
    setBusyAccount(accountId);
    setError("");
    try {
      const result = await requestJson(
        `${ACCOUNT_URL}?accountId=${encodeURIComponent(accountId)}`,
        decodeAccounts,
        {
          method: "DELETE",
        },
      );
      setAccounts(result.accounts);
      setDisconnecting(null);
    } catch (disconnectError) {
      setError(disconnectError instanceof Error ? disconnectError.message : "Disconnect failed");
    } finally {
      setBusyAccount(null);
    }
  };

  const visibleAccounts = useMemo(() => {
    const normalized = searchQuery.trim().toLowerCase();
    if (!normalized) return accounts;
    return accounts.filter((account) =>
      `${account.label} ${account.organization} Code.Storage`.toLowerCase().includes(normalized),
    );
  }, [accounts, searchQuery]);

  return (
    <>
      {error ? (
        <div className="mb-4">
          <Alert variant="error">{error}</Alert>
        </div>
      ) : null}
      <TableSection
        title="Code.Storage"
        description="Authenticated repository accounts agents can clone, fetch, list, and push through scoped credentials."
        actions={
          <div className="flex items-center gap-2">
            <StatusText tone={error ? "warn" : loaded ? "ok" : "dim"}>
              {loaded ? `${accounts.length} connected` : "loading"}
            </StatusText>
            <RefreshIconButton onClick={refresh} loading={refreshing} label="Refresh accounts" />
            <Button size="sm" onClick={() => setOpen(true)}>
              <Plus className="h-3 w-3" />
              Connect
            </Button>
          </div>
        }
      >
        {!loaded ? (
          <TableSkeleton columns={ACCOUNT_COLUMNS} rows={1} minWidthClass={ACCOUNT_MIN_WIDTH} />
        ) : visibleAccounts.length === 0 ? (
          <TableNotice
            title={accounts.length ? "No account matches this search" : "No account connected"}
            body={
              accounts.length
                ? "Search by account label or organization."
                : "Connect an organization private key to give agents scoped repository access."
            }
          />
        ) : (
          <TableFrame minWidthClass={ACCOUNT_MIN_WIDTH}>
            <thead>
              <tr>
                {ACCOUNT_COLUMNS.map((column, index) => (
                  <HeadCell key={column} numeric={index === ACCOUNT_COLUMNS.length - 1}>
                    {column}
                  </HeadCell>
                ))}
              </tr>
            </thead>
            <tbody>
              {visibleAccounts.map((account) => {
                const confirming = disconnecting === account.id;
                const busy = busyAccount === account.id;
                return (
                  <DataRow key={account.id} ariaLabel={`${account.label} Code.Storage account`}>
                    <IdentityCell
                      leading={
                        <ResourceLogo
                          identity="code-storage"
                          label="Code.Storage"
                          company="The Pierre Computer Company"
                        />
                      }
                      label={account.label}
                      description={`Connected ${new Date(account.connectedAt).toLocaleDateString()}`}
                    />
                    <TextCell mono>{account.organization}</TextCell>
                    <EndCell>
                      <div className="flex items-center justify-end gap-2">
                        <StatusText tone="ok">{account.secretProvider}</StatusText>
                        {confirming ? (
                          <>
                            <RowAction
                              alwaysVisible
                              disabled={busy}
                              onClick={() => setDisconnecting(null)}
                              title="Keep account connected"
                            >
                              Keep
                            </RowAction>
                            <RowAction
                              alwaysVisible
                              disabled={busy}
                              onClick={() => void disconnect(account.id)}
                              tone="danger"
                              title={`Disconnect ${account.label}`}
                            >
                              Confirm
                            </RowAction>
                          </>
                        ) : (
                          <RowAction
                            alwaysVisible
                            disabled={Boolean(busyAccount)}
                            onClick={() => setDisconnecting(account.id)}
                            tone="danger"
                            title={`Disconnect ${account.label}`}
                          >
                            Disconnect
                          </RowAction>
                        )}
                      </div>
                    </EndCell>
                  </DataRow>
                );
              })}
            </tbody>
          </TableFrame>
        )}
      </TableSection>
      {open ? (
        <CodeStorageAccountModal
          onClose={() => setOpen(false)}
          onChanged={(nextAccounts) => {
            setAccounts(nextAccounts);
            setLoaded(true);
          }}
        />
      ) : null}
    </>
  );
}
