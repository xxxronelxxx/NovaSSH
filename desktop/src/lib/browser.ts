import type { DirListing, Server } from "./api";

export interface BrowserTab {
  id: string;
  label: string;
  server: Server;
  sessionId: string;
  listing: DirListing | null;
  disconnected?: boolean;
  uname?: string;
}
