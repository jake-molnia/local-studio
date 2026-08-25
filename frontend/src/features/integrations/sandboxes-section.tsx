"use client";

import { Schema } from "effect";
import { useCallback, useMemo, useState } from "react";
import {
  SandboxAccountsResponseSchema,
  type SandboxAccountEntry,
  type SandboxProvider,
} from "@shared/agent/sandbox-account-contract";
import {
  Alert,
  Button,
  FormField,
  Input,
  RefreshIconButton,
  Select,
  UiModal,
  UiModalBody,
  UiModalHeader,
} from "@/ui";
import { Boxes, Eye, EyeOff, Plus, X } from "@/ui/icon-registry";
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

const ACCOUNT_URL = "/api/agent/accounts/sandboxes";
const decodeAccounts = Schema.decodeUnknownSync(SandboxAccountsResponseSchema);
const PROVIDERS: Array<{ id: SandboxProvider; label: string; company: string }> = [
  { id: "modal", label: "Modal", company: "Modal Labs" },
  { id: "daytona", label: "Daytona", company: "Daytona Platforms" },
];
const COLUMNS = ["Account", "Endpoint", "State"] as const;

export function SandboxAccountModal({
  initialProvider,
  accounts = [],
  onClose,
  onChanged,
}: {
  initialProvider?: SandboxProvider;
  accounts?: readonly SandboxAccountEntry[];
  onClose: () => void;
  onChanged: (accounts: readonly SandboxAccountEntry[]) => void;
}) {
  const [provider, setProvider] = useState<SandboxProvider>(initialProvider ?? "modal");
  const [label, setLabel] = useState("");
  const [tokenId, setTokenId] = useState("");
  const [tokenSecret, setTokenSecret] = useState("");
  const [apiKey, setApiKey] = useState("");
  const [endpoint, setEndpoint] = useState("https://app.daytona.io/api");
  const [showSecrets, setShowSecrets] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const connected = accounts.filter((account) => account.provider === provider);
  const valid =
    provider === "modal"
      ? tokenId.trim().length > 0 && tokenSecret.trim().length > 0
      : apiKey.trim().length > 0 && endpoint.trim().length > 0;

  const connect = async () => {
    setBusy(true);
    setError("");
    try {
      const result = await requestJson(ACCOUNT_URL, decodeAccounts, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          provider,
          label: label.trim() || undefined,
          ...(provider === "modal"
            ? { tokenId, tokenSecret }
            : { apiKey, endpoint: endpoint.trim() }),
        }),
      });
      setTokenSecret("");
      setApiKey("");
      onChanged(result.accounts);
      onClose();
    } catch (connectError) {
      setError(connectError instanceof Error ? connectError.message : "Connection failed");
    } finally {
      setBusy(false);
    }
  };

  const disconnect = async (accountId: string) => {
    setBusy(true);
    setError("");
    try {
      const result = await requestJson(
        `${ACCOUNT_URL}?accountId=${encodeURIComponent(accountId)}`,
        decodeAccounts,
        { method: "DELETE" },
      );
      onChanged(result.accounts);
    } catch (disconnectError) {
      setError(disconnectError instanceof Error ? disconnectError.message : "Disconnect failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <UiModal isOpen onClose={busy ? () => undefined : onClose} maxWidth="max-w-lg">
      <UiModalHeader
        title="Connect sandbox provider"
        icon={<Boxes className="h-4 w-4 text-(--ui-info)" />}
        onClose={onClose}
        showCloseButton={!busy}
        closeIcon={<X className="h-4 w-4" />}
      />
      <UiModalBody className="space-y-4 pb-5">
        <Alert variant="info">
          This stores the login only. Sandbox creation and execution are not enabled yet.
        </Alert>
        {error ? <Alert variant="error">{error}</Alert> : null}
        {connected.length ? (
          <div className="rounded-md border border-(--ui-separator)">
            {connected.map((account) => (
              <div
                key={account.id}
                className="flex items-center gap-3 border-b border-(--ui-separator) px-3 py-2 last:border-b-0"
              >
                <div className="min-w-0 flex-1">
                  <div className="truncate text-[length:var(--fs-sm)] text-(--ui-fg)">
                    {account.label}
                  </div>
                  <div className="truncate font-mono text-[length:var(--fs-xs)] text-(--ui-muted)">
                    {account.endpoint}
                  </div>
                </div>
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={busy}
                  onClick={() => void disconnect(account.id)}
                >
                  Disconnect
                </Button>
              </div>
            ))}
          </div>
        ) : null}
        <FormField label="Provider">
          <Select
            value={provider}
            disabled={Boolean(initialProvider)}
            onChange={(event) => setProvider(event.target.value as SandboxProvider)}
            options={PROVIDERS.map((entry) => ({ value: entry.id, label: entry.label }))}
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
        {provider === "modal" ? (
          <>
            <FormField label="Token ID">
              <Input
                value={tokenId}
                onChange={(event) => setTokenId(event.target.value)}
                autoComplete="off"
                className="font-mono"
              />
            </FormField>
            <FormField label="Token secret">
              <div className="relative">
                <Input
                  value={tokenSecret}
                  onChange={(event) => setTokenSecret(event.target.value)}
                  type={showSecrets ? "text" : "password"}
                  autoComplete="off"
                  className="pr-10 font-mono"
                />
                <SecretVisibility
                  visible={showSecrets}
                  onToggle={() => setShowSecrets(!showSecrets)}
                />
              </div>
            </FormField>
          </>
        ) : (
          <>
            <FormField label="API endpoint">
              <Input
                value={endpoint}
                onChange={(event) => setEndpoint(event.target.value)}
                autoComplete="off"
                className="font-mono"
              />
            </FormField>
            <FormField label="API key">
              <div className="relative">
                <Input
                  value={apiKey}
                  onChange={(event) => setApiKey(event.target.value)}
                  type={showSecrets ? "text" : "password"}
                  autoComplete="off"
                  className="pr-10 font-mono"
                />
                <SecretVisibility
                  visible={showSecrets}
                  onToggle={() => setShowSecrets(!showSecrets)}
                />
              </div>
            </FormField>
          </>
        )}
        <div className="flex justify-end gap-2">
          <Button variant="secondary" disabled={busy} onClick={onClose}>
            Cancel
          </Button>
          <Button loading={busy} disabled={!valid} onClick={() => void connect()}>
            Connect account
          </Button>
        </div>
      </UiModalBody>
    </UiModal>
  );
}

function SecretVisibility({ visible, onToggle }: { visible: boolean; onToggle: () => void }) {
  return (
    <button
      type="button"
      onClick={onToggle}
      className="absolute right-2 top-1/2 -translate-y-1/2 rounded p-1 text-(--ui-muted) hover:text-(--ui-fg)"
      aria-label={visible ? "Hide credential" : "Show credential"}
    >
      {visible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
    </button>
  );
}

export function SandboxesSection({ searchQuery = "" }: { searchQuery?: string } = {}) {
  const [accounts, setAccounts] = useState<readonly SandboxAccountEntry[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [open, setOpen] = useState(false);
  const [error, setError] = useState("");

  const refresh = useCallback(() => {
    setRefreshing(true);
    void requestJson(ACCOUNT_URL, decodeAccounts, { cache: "no-store" })
      .then((result) => {
        setAccounts(result.accounts);
        setError("");
      })
      .catch((loadError: unknown) => {
        setError(loadError instanceof Error ? loadError.message : "Sandbox accounts failed");
      })
      .finally(() => {
        setLoaded(true);
        setRefreshing(false);
      });
  }, []);

  useMountSubscription(refresh, [refresh]);
  const visibleAccounts = useMemo(() => {
    const query = searchQuery.trim().toLowerCase();
    return query
      ? accounts.filter((account) =>
          `${account.label} ${account.provider} ${account.endpoint}`.toLowerCase().includes(query),
        )
      : accounts;
  }, [accounts, searchQuery]);

  const disconnect = async (accountId: string) => {
    try {
      const result = await requestJson(
        `${ACCOUNT_URL}?accountId=${encodeURIComponent(accountId)}`,
        decodeAccounts,
        { method: "DELETE" },
      );
      setAccounts(result.accounts);
    } catch (disconnectError) {
      setError(disconnectError instanceof Error ? disconnectError.message : "Disconnect failed");
    }
  };

  return (
    <>
      {error ? <Alert variant="error">{error}</Alert> : null}
      <TableSection
        title="Sandboxes"
        description="Stored logins for Modal and Daytona. Runtime abilities will be added separately."
        actions={
          <div className="flex items-center gap-2">
            <StatusText tone={loaded ? "ok" : "dim"}>
              {loaded ? `${accounts.length} connected` : "loading"}
            </StatusText>
            <RefreshIconButton onClick={refresh} loading={refreshing} label="Refresh accounts" />
            <Button size="sm" onClick={() => setOpen(true)}>
              <Plus className="h-3 w-3" /> Connect
            </Button>
          </div>
        }
      >
        {!loaded ? (
          <TableSkeleton columns={COLUMNS} rows={2} minWidthClass="min-w-[34rem]" />
        ) : visibleAccounts.length === 0 ? (
          <TableNotice
            title={
              accounts.length ? "No account matches this search" : "No sandbox login connected"
            }
            body="Connect Modal or Daytona credentials. This does not enable sandbox execution yet."
          />
        ) : (
          <TableFrame minWidthClass="min-w-[34rem]">
            <thead>
              <tr>
                {COLUMNS.map((column, index) => (
                  <HeadCell key={column} numeric={index === COLUMNS.length - 1}>
                    {column}
                  </HeadCell>
                ))}
              </tr>
            </thead>
            <tbody>
              {visibleAccounts.map((account) => {
                const provider = PROVIDERS.find((entry) => entry.id === account.provider);
                return (
                  <DataRow key={account.id} ariaLabel={`${account.label} sandbox account`}>
                    <IdentityCell
                      leading={
                        <ResourceLogo
                          identity={account.provider}
                          label={provider?.label ?? account.provider}
                          company={provider?.company}
                        />
                      }
                      label={account.label}
                      description={provider?.label ?? account.provider}
                    />
                    <TextCell mono>{account.endpoint}</TextCell>
                    <EndCell>
                      <div className="flex items-center justify-end gap-2">
                        <StatusText tone="ok">stored</StatusText>
                        <RowAction
                          alwaysVisible
                          tone="danger"
                          title={`Disconnect ${account.label}`}
                          onClick={() => void disconnect(account.id)}
                        >
                          Disconnect
                        </RowAction>
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
        <SandboxAccountModal
          accounts={accounts}
          onClose={() => setOpen(false)}
          onChanged={(next) => {
            setAccounts(next);
            setLoaded(true);
          }}
        />
      ) : null}
    </>
  );
}
