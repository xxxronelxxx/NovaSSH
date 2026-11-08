<script lang="ts">
  import PaneCard from "../lib/PaneCard.svelte";
  import Toolbar from "../lib/Toolbar.svelte";
  import TransferPanel from "../lib/TransferPanel.svelte";
  import type { BrowserTab } from "../lib/browser";
  import type {
    DirListing,
    Entry,
    TransferEvent,
    Volume,
  } from "../lib/api";

  let {
    tabs,
    activeTabId,
    local,
    volumes = [],
    transfers = [],
    onSelectTab,
    onAddTab,
    onBack,
    onLocalPath,
    onRemotePath,
    onDownload,
  }: {
    tabs: BrowserTab[];
    activeTabId: string;
    local: DirListing | null;
    volumes?: Volume[];
    transfers?: TransferEvent[];
    onSelectTab: (id: string) => void;
    onAddTab: () => void;
    onBack: () => void;
    onLocalPath: (path: string) => void;
    onRemotePath: (tabId: string, path: string) => void;
    onDownload: (remotePath: string, targetDir: string) => void;
  } = $props();

  let focused = $state<"local" | "remote">("local");
  let localSel = $state<string | null>(null);
  let remoteSel = $state<string | null>(null);
  let filter = $state("");
  let transferCollapsed = $state(false);

  const tab = $derived(tabs.find((item) => item.id === activeTabId) ?? null);
  const remote = $derived(tab?.listing ?? null);

  $effect(() => {
    // Switching servers must not keep a stale selection.
    activeTabId;
    remoteSel = null;
  });

  const localTabs = $derived(
    volumes.length
      ? volumes.map((volume) => ({ id: volume.path, label: volume.name }))
      : [{ id: "local", label: "Локально" }],
  );

  const localActive = $derived.by(() => {
    const path = local?.path?.toLowerCase() ?? "";
    const match = volumes.find((volume) =>
      path.startsWith(volume.path.toLowerCase()),
    );
    return match?.path ?? localTabs[0]?.id ?? "local";
  });

  const selectedRemoteEntry = $derived(
    (remote?.entries ?? []).find((entry) => entry.path === remoteSel) ?? null,
  );

  const canDownload = $derived(
    !!tab && !!local && !!selectedRemoteEntry &&
      selectedRemoteEntry.kind !== "dir",
  );

  function up() {
    if (focused === "local") {
      if (local?.parent) onLocalPath(local.parent);
    } else if (tab && remote?.parent) {
      onRemotePath(tab.id, remote.parent);
    }
  }

  function refresh() {
    if (focused === "local" && local) onLocalPath(local.path);
    else if (tab && remote) onRemotePath(tab.id, remote.path);
  }

  function download() {
    if (!tab || !local || !selectedRemoteEntry) return;
    if (selectedRemoteEntry.kind === "dir") return;
    onDownload(selectedRemoteEntry.path, local.path);
  }

  function openLocal(entry: Entry) {
    if (entry.kind === "dir") onLocalPath(entry.path);
  }

  function openRemote(entry: Entry) {
    if (tab && entry.kind === "dir") onRemotePath(tab.id, entry.path);
  }

  function selectLocalTab(id: string) {
    onLocalPath(id === "local" ? (local?.path ?? "") : id);
  }
</script>

<div class="browser">
  <Toolbar
    canUp={focused === "local" ? !!local?.parent : !!remote?.parent}
    canDownload={canDownload}
    filter={filter}
    onBack={onBack}
    onUp={up}
    onRefresh={refresh}
    onDownload={download}
    onFilter={(value) => (filter = value)}
  />

  <div class="panes">
    <PaneCard
      variant="local"
      tabs={localTabs}
      activeTab={localActive}
      listing={local}
      selected={localSel}
      focused={focused === "local"}
      filter={focused === "local" ? filter : ""}
      onSelectTab={selectLocalTab}
      onAdd={() => {}}
      onUp={() => local?.parent && onLocalPath(local.parent)}
      onRefresh={() => local && onLocalPath(local.path)}
      onPath={onLocalPath}
      onSelect={(entry) => {
        focused = "local";
        localSel = entry.path;
      }}
      onOpen={openLocal}
      onFocus={() => (focused = "local")}
    />

    <PaneCard
      variant="remote"
      tabs={tabs.map((item) => ({
        id: item.id,
        label: item.label,
        hint: `${item.server.user}@${item.server.host}`,
      }))}
      activeTab={activeTabId}
      listing={remote}
      selected={remoteSel}
      focused={focused === "remote"}
      filter={focused === "remote" ? filter : ""}
      canAdd
      onSelectTab={onSelectTab}
      onAdd={onAddTab}
      onUp={() => tab && remote?.parent && onRemotePath(tab.id, remote.parent)}
      onRefresh={() => tab && remote && onRemotePath(tab.id, remote.path)}
      onPath={(path) => tab && onRemotePath(tab.id, path)}
      onSelect={(entry) => {
        focused = "remote";
        remoteSel = entry.path;
      }}
      onOpen={openRemote}
      onFocus={() => (focused = "remote")}
    />
  </div>

  <div class="transfer-wrap">
    <TransferPanel
      transfers={transfers}
      collapsed={transferCollapsed}
      onToggle={() => (transferCollapsed = !transferCollapsed)}
    />
  </div>
</div>

<style>
  .browser {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
  }

  .panes {
    flex: 1;
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px;
    min-height: 0;
    padding: 0 18px 10px;
  }

  .transfer-wrap {
    padding: 0 18px 14px;
  }
</style>
