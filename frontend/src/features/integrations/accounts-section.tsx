"use client";

import { GoogleAccountsSection } from "./google-accounts-section";

export function AccountsSection({ searchQuery = "" }: { searchQuery?: string } = {}) {
  return (
    <div className="space-y-5">
      <GoogleAccountsSection searchQuery={searchQuery} />
    </div>
  );
}
