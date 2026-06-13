import {
  Children,
  cloneElement,
  isValidElement,
  type ReactElement,
  type ReactNode,
} from "react";
import { reconcileVisibleTableColumns } from "./tableState";

type DataTableProps = {
  "aria-label": string;
  children: ReactNode;
  className?: string;
  columns?: DataTableColumn[];
  onVisibleColumnsChange?: (visibleColumns: string[]) => void;
  stickyFirstColumn?: boolean;
  visibleColumns?: string[];
};

export type DataTableColumn = {
  id: string;
  label: string;
  locked?: boolean;
};

export function DataTable({
  "aria-label": ariaLabel,
  children,
  className,
  columns,
  onVisibleColumnsChange,
  stickyFirstColumn = false,
  visibleColumns,
}: DataTableProps) {
  const reconciledVisibleColumns = columns?.length
    ? reconcileVisibleTableColumns(columns, visibleColumns)
    : [];
  const activeColumnIds = columns?.length
    ? new Set(reconciledVisibleColumns)
    : null;
  const tableChildren = activeColumnIds && columns
    ? filterTableChildren(children, columns, activeColumnIds)
    : children;
  const tableClassName = [
    "data-table",
    stickyFirstColumn ? "data-table--sticky-first" : null,
    className,
  ].filter(Boolean).join(" ");

  return (
    <div className="data-table-wrap">
      {columns?.length && onVisibleColumnsChange ? (
        <DataTableColumnMenu
          columns={columns}
          visibleColumns={reconciledVisibleColumns}
          onVisibleColumnsChange={onVisibleColumnsChange}
        />
      ) : null}
      <table aria-label={ariaLabel} className={tableClassName}>
        {tableChildren}
      </table>
    </div>
  );
}

function DataTableColumnMenu({
  columns,
  onVisibleColumnsChange,
  visibleColumns,
}: {
  columns: DataTableColumn[];
  onVisibleColumnsChange: (visibleColumns: string[]) => void;
  visibleColumns: string[];
}) {
  const visibleSet = new Set(visibleColumns);

  function toggleColumn(column: DataTableColumn) {
    if (column.locked) {
      return;
    }

    const nextVisible = visibleSet.has(column.id)
      ? visibleColumns.filter((id) => id !== column.id)
      : columns.map((item) => item.id).filter((id) => id === column.id || visibleSet.has(id));
    const lockedIds = columns.filter((item) => item.locked).map((item) => item.id);
    onVisibleColumnsChange(Array.from(new Set([...lockedIds, ...nextVisible])));
  }

  return (
    <div className="data-table-tools" aria-label="表格列设置">
      <span>列显示</span>
      <div className="data-table-column-list">
        {columns.map((column) => (
          <label key={column.id} className="data-table-column-toggle">
            <input
              checked={visibleSet.has(column.id)}
              disabled={column.locked}
              type="checkbox"
              onChange={() => toggleColumn(column)}
            />
            {column.label}
          </label>
        ))}
      </div>
    </div>
  );
}

function filterTableChildren(children: ReactNode, columns: DataTableColumn[], visibleColumnIds: Set<string>): ReactNode {
  return Children.map(children, (child) => {
    if (!isValidElement(child)) {
      return child;
    }

    const element = child as ReactElement<{ children?: ReactNode }>;

    return cloneElement(element, {
      children: filterTableSectionChildren(element.props.children, columns, visibleColumnIds),
    });
  });
}

function filterTableSectionChildren(
  children: ReactNode,
  columns: DataTableColumn[],
  visibleColumnIds: Set<string>,
): ReactNode {
  return Children.map(children, (child) => {
    if (!isValidElement(child)) {
      return child;
    }

    const element = child as ReactElement<{ children?: ReactNode }>;

    return cloneElement(element, {
      children: filterRowCells(element.props.children, columns, visibleColumnIds),
    });
  });
}

function filterRowCells(children: ReactNode, columns: DataTableColumn[], visibleColumnIds: Set<string>): ReactNode {
  let cellIndex = 0;

  return Children.toArray(children).filter((child) => {
    if (!isValidElement(child)) {
      return true;
    }

    const props = child.props as { colSpan?: number };
    if (props.colSpan && props.colSpan > 1) {
      return true;
    }

    const column = columns[cellIndex];
    cellIndex += 1;

    return column ? visibleColumnIds.has(column.id) : true;
  });
}
