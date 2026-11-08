import type { DirListing, Server } from "./api";

export interface ArchiveState {
  path: string;
  parent: string;
  inner: string;
  listing: DirListing | null;
}

export interface BrowserTab {
  id: string;
  label: string;
  server: Server;
  sessionId: string;
  listing: DirListing | null;
  local: DirListing | null;
  localSel: string[];
  remoteSel: string[];
  archive: ArchiveState | null;
  localCursor: string | null;
  localSort: { key: string; asc: boolean };
  filter: string;
  disconnected?: boolean;
  disconnectReason?: string;
  uname?: string;
}
