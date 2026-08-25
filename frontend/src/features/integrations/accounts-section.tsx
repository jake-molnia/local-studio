"use client";

import { CodeStorageAccountsSection } from "./code-storage-accounts-section";
import { GoogleAccountsSection } from "./google-accounts-section";

export function AccountsSection({ searchQuery = "" }: { searchQuery?: string } = {}) {
  return (
    <div className="space-y-5">
      <CodeStorageAccountsSection searchQuery={searchQuery} />
      <GoogleAccountsSection searchQuery={searchQuery} />
    </div>
  );
}
