import { useState, useEffect, useCallback } from "react";
import { getAccounts, getChildren } from "@/lib/database/repository";
import type { Account, Child } from "@/types";

export function useAccountData() {
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [children, setChildren] = useState<Child[]>([]);
  const [loading, setLoading] = useState(true);

  const reload = useCallback(async () => {
    setLoading(true);
    const [accts, kids] = await Promise.all([getAccounts(), getChildren()]);
    setAccounts(accts);
    setChildren(kids);
    setLoading(false);
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  return { accounts, children, loading, reload };
}
