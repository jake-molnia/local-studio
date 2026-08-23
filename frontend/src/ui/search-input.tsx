"use client";

import { Search, X } from "@/ui/icon-registry";

interface SearchInputProps {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  onClear?: () => void;
  className?: string;
  "aria-label"?: string;
}

function SearchInput({
  value,
  onChange,
  placeholder = "Search...",
  onClear,
  className = "",
  "aria-label": ariaLabel,
}: SearchInputProps) {
  const handleClear = () => {
    if (onClear) {
      onClear();
    } else {
      onChange("");
    }
  };

  return (
    <div className={`relative ${className}`}>
      <Search className="absolute left-2 top-1/2 h-3 w-3 -translate-y-1/2 text-(--ui-muted)" />
      <input
        type="text"
        data-ui-control="field"
        value={value}
        aria-label={ariaLabel}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        className="h-[var(--control-height)] w-full rounded-[4px] border border-(--ui-separator) bg-(--ui-surface) pl-7 pr-7 text-[length:var(--fs-sm)] text-(--ui-fg) transition-[background-color,border-color] placeholder:text-(--ui-muted)/70 focus:border-(--ui-border-heavy) focus:outline-none"
      />
      {value && (
        <button
          type="button"
          data-ui-control="compact"
          onClick={handleClear}
          className="absolute right-1.5 top-1/2 -translate-y-1/2 rounded-[3px] p-1 transition-colors hover:bg-(--ui-hover)"
          aria-label="Clear search"
        >
          <X className="h-3.5 w-3.5 text-(--ui-muted)" />
        </button>
      )}
    </div>
  );
}

export { SearchInput };
export type { SearchInputProps };
