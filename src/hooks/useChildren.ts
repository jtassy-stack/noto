import { createContext, useContext } from "react";
import type { Child } from "@/types";

export interface ChildrenContextValue {
  children: Child[];
  activeChild: Child | null;
  setActiveChildId: (id: string) => void;
}

export const ChildrenContext = createContext<ChildrenContextValue>({
  children: [],
  activeChild: null,
  setActiveChildId: () => {},
});

export function useChildren() {
  return useContext(ChildrenContext);
}
