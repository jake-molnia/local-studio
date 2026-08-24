"use client";

import { RIG_HARDWARE_TYPE_LABELS, RIG_NODE_ROLE_LABELS } from "@local-studio/contracts/rigs";
import { DashboardLayout } from "@/features/dashboard/layout/dashboard-layout";
import { useDashboardData } from "@/features/dashboard/use-dashboard-data";
import { StatusPill, type UiTone } from "@/ui";
import type { RigNode, WorkerStatus } from "@/lib/types";
import { SettingsFactRows, SettingsGroup, type SettingsFactRow } from "./settings-ui";

type MachineState = {
  label: string;
  tone: UiTone;
};

const machineState = (
  node: RigNode,
  worker: WorkerStatus | undefined,
  headConnected: boolean,
): MachineState => {
  if (worker) {
    return worker.healthy
      ? { label: "online", tone: "good" }
      : { label: "offline", tone: "danger" };
  }
  if (node.role === "head") {
    return headConnected ? { label: "online", tone: "good" } : { label: "offline", tone: "danger" };
  }
  return node.address
    ? { label: "configured", tone: "info" }
    : { label: "unavailable", tone: "warning" };
};

const endpoint = (node: RigNode): string => node.address ?? node.hostname ?? "Not reported";

const acceleratorSummary = (node: RigNode): string => {
  if (node.accelerators.length === 0) return "None reported";
  return node.accelerators
    .map((accelerator) =>
      accelerator.count > 1 ? `${accelerator.count} × ${accelerator.name}` : accelerator.name,
    )
    .join(", ");
};

const capabilityRows = (node: RigNode): SettingsFactRow[] => {
  const capabilities = node.capabilities;
  const readiness = (
    label: string,
    ready: boolean | undefined,
    description: string,
  ): SettingsFactRow => ({
    label,
    description,
    value: ready === undefined ? "Not reported" : ready ? "Available" : "Unavailable",
    status: {
      label: ready === undefined ? "unknown" : ready ? "ready" : "missing",
      tone: ready === undefined ? "default" : ready ? "good" : "warning",
    },
  });
  return [
    readiness("Compute runtime", capabilities?.compute, "Runs local inference workloads."),
    readiness("Terminal", capabilities?.terminal, "Provides task-scoped terminal sessions."),
    readiness("Browser", capabilities?.browser, "Provides browser automation to agent tasks."),
    readiness("MCP", capabilities?.mcp, "Exposes configured Model Context Protocol services."),
    {
      label: "Agent harnesses",
      description: "External agent runtimes available on this machine.",
      value: capabilities?.harnesses.length ? capabilities.harnesses.join(", ") : "None reported",
      status: {
        label: capabilities?.harnesses.length ? "ready" : capabilities ? "missing" : "unknown",
        tone: capabilities?.harnesses.length ? "good" : capabilities ? "warning" : "default",
      },
    },
  ];
};

export function LocalMachineStatus() {
  const data = useDashboardData();
  return (
    <div className="-mx-3 -mt-2 sm:-mx-4">
      <DashboardLayout {...data} />
    </div>
  );
}

export function MachineStatusSettings({
  node,
  worker,
  headConnected,
}: {
  node: RigNode;
  worker?: WorkerStatus;
  headConnected: boolean;
}) {
  const state = machineState(node, worker, headConnected);
  return (
    <div className="space-y-5">
      <SettingsGroup
        title="Machine status"
        description="Current reachability and workload state for this machine."
        actions={<StatusPill tone={state.tone}>{state.label}</StatusPill>}
      >
        <SettingsFactRows
          rows={[
            { label: "Role", value: RIG_NODE_ROLE_LABELS[node.role] },
            { label: "Endpoint", value: endpoint(node), mono: true },
            { label: "Active streams", value: worker?.active_streams ?? "Not reported" },
            { label: "Available models", value: worker?.models.length ?? "Not reported" },
            {
              label: "Last checked",
              value: worker?.checked_at
                ? new Date(worker.checked_at).toLocaleString()
                : "Not reported",
            },
            ...(worker?.error
              ? [
                  {
                    label: "Last error",
                    value: worker.error,
                    status: { label: "error", tone: "danger" as const },
                  },
                ]
              : []),
          ]}
        />
      </SettingsGroup>
      <SettingsGroup
        title="Workload readiness"
        description="Capabilities this machine reports to the Head."
      >
        <SettingsFactRows rows={capabilityRows(node)} />
      </SettingsGroup>
    </div>
  );
}

export function MachineControllerSettings({
  node,
  worker,
  headConnected,
}: {
  node: RigNode;
  worker?: WorkerStatus;
  headConnected: boolean;
}) {
  const state = machineState(node, worker, headConnected);
  return (
    <SettingsGroup
      title="Controller"
      description="Controller reachability and routing state for this machine."
      actions={<StatusPill tone={state.tone}>{state.label}</StatusPill>}
    >
      <SettingsFactRows
        rows={[
          { label: "Endpoint", value: endpoint(node), mono: true },
          { label: "Role", value: RIG_NODE_ROLE_LABELS[node.role] },
          { label: "Active streams", value: worker?.active_streams ?? "Not reported" },
          { label: "Registered models", value: worker?.models.length ?? "Not reported" },
          {
            label: "Controller error",
            value: worker?.error ?? "No error reported",
            status: worker?.error
              ? { label: "error", tone: "danger" }
              : { label: "clear", tone: "good" },
          },
        ]}
      />
    </SettingsGroup>
  );
}

export function MachineSystemSettings({ node }: { node: RigNode }) {
  return (
    <div className="space-y-5">
      <SettingsGroup
        title="System"
        description="Hardware and operating-system details reported by this machine."
      >
        <SettingsFactRows
          rows={[
            { label: "Hardware", value: RIG_HARDWARE_TYPE_LABELS[node.hardware_type] },
            { label: "Operating system", value: node.os ?? "Not reported" },
            { label: "Hostname", value: node.hostname ?? "Not reported", mono: true },
            { label: "Processor", value: node.cpu_model ?? "Not reported" },
            { label: "CPU cores", value: node.cpu_cores ?? "Not reported" },
            {
              label: "System memory",
              value: node.memory_gb ? `${node.memory_gb} GB` : "Not reported",
            },
            { label: "Accelerators", value: acceleratorSummary(node), wrap: true },
          ]}
        />
      </SettingsGroup>
      <SettingsGroup
        title="Dependencies & apps"
        description="Services this machine must expose for agent and inference workloads."
      >
        <SettingsFactRows rows={capabilityRows(node)} />
      </SettingsGroup>
    </div>
  );
}
