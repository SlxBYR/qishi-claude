// Builds the Clawd theme exactly as upstream's main process hands it to the renderer:
// theme-schema mergeDefaults() (objectScale/layout/timing derivation) + theme-context getRendererConfig().
const [upstream, themeJson] = process.argv.slice(2);
const schema = require(`${upstream}/theme-schema.js`);
const createThemeContext = require(`${upstream}/theme-context.js`);
const theme = schema.mergeDefaults(JSON.parse(require("fs").readFileSync(themeJson, "utf8")), "clawd", true);
theme._themeDir = "/nonexistent";
theme._capabilities = schema.buildCapabilities(theme, { trustedRuntimeAllowed: true });
const config = Object.fromEntries(Object.entries(theme).filter(([key]) => !key.startsWith("_")));
Object.assign(config, createThemeContext(theme).getRendererConfig(), { assetsPath: "assets", sourceAssetsPath: null });
process.stdout.write(`window.themeConfig = ${JSON.stringify(config)};\n`);
