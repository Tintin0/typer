/**
 * Compatibility page entry.
 *
 * FOUNDATION PLACEHOLDER (this wave): imports the shared design system and mounts
 * shared chrome. The compatibility-page agent (next wave) renders the full per-app
 * matrix (docs/marketing/design-system.md §5.7 + positioning.md §6) into
 * <main id="compatibility">, keeping these two lines:
 *
 *     import "./styles.css";
 *     mountChrome("compatibility");
 */
import "./styles.css";
import { mountChrome } from "./shell";

mountChrome("compatibility");
