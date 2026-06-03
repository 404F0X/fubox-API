import { readFile, readdir, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const DEFAULT_JS_BUDGET_KIB = 250;
const assetsUrl = new URL("../dist/assets/", import.meta.url);
const indexUrl = new URL("../dist/index.html", import.meta.url);

function readBudgetKiB() {
  const rawBudget = process.env.ADMIN_UI_BUNDLE_BUDGET_KIB;

  if (rawBudget === undefined || rawBudget.trim() === "") {
    return DEFAULT_JS_BUDGET_KIB;
  }

  const budget = Number(rawBudget);

  if (!Number.isFinite(budget) || budget <= 0) {
    throw new Error("ADMIN_UI_BUNDLE_BUDGET_KIB must be a positive number.");
  }

  return budget;
}

function formatKiB(bytes) {
  return `${(bytes / 1024).toFixed(1)} KiB`;
}

async function main() {
  const budgetKiB = readBudgetKiB();
  const budgetBytes = budgetKiB * 1024;
  let entries;

  try {
    entries = await readdir(assetsUrl, { withFileTypes: true });
  } catch {
    throw new Error(`Could not read ${fileURLToPath(assetsUrl)}. Run npm run build first.`);
  }

  const jsAssetNames = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".js"))
    .map((entry) => entry.name)
    .sort();

  if (jsAssetNames.length === 0) {
    throw new Error(`No built JS assets found in ${fileURLToPath(assetsUrl)}. Run npm run build first.`);
  }

  const assets = await Promise.all(
    jsAssetNames.map(async (name) => {
      const assetUrl = new URL(name, assetsUrl);
      const assetStat = await stat(assetUrl);

      return {
        name,
        size: assetStat.size,
      };
    }),
  );

  const indexHtml = await readFile(indexUrl, "utf8");
  const initialAssets = assets.filter((asset) => indexHtml.includes(`assets/${asset.name}`));
  const lazyAssets = assets.filter((asset) => !initialAssets.includes(asset));

  if (initialAssets.length === 0) {
    throw new Error(`No initial JS assets were referenced by ${fileURLToPath(indexUrl)}.`);
  }

  const initialBytes = initialAssets.reduce((sum, asset) => sum + asset.size, 0);
  const totalBytes = assets.reduce((sum, asset) => sum + asset.size, 0);

  console.log("Initial JS assets:");
  for (const asset of initialAssets) {
    console.log(`  ${asset.name}: ${formatKiB(asset.size)}`);
  }
  if (lazyAssets.length > 0) {
    console.log("Lazy JS assets:");
    for (const asset of lazyAssets) {
      console.log(`  ${asset.name}: ${formatKiB(asset.size)}`);
    }
  }
  console.log(`Initial JS: ${formatKiB(initialBytes)} / ${formatKiB(budgetBytes)}`);
  console.log(`Total JS: ${formatKiB(totalBytes)}`);

  if (initialBytes > budgetBytes) {
    throw new Error(
      `Initial bundle budget exceeded by ${formatKiB(initialBytes - budgetBytes)}. ` +
        "Raise ADMIN_UI_BUNDLE_BUDGET_KIB only with an intentional bundle-size change.",
    );
  }

  console.log("Bundle budget OK.");
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
