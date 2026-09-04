// tests/fixtures/cc/2.1.259-grep-operand-extractor.js
//
// HISTORICAL REGRESSION FIXTURE — Claude Code 2.1.259's grep-family path-operand extractor,
// lifted VERBATIM from the installed executable and wrapped so it runs after that build is
// uninstalled. It is the evidence that falsified dhx-cd-compound-read-allow.sh's ARM 2
// (docs/decisions.md 2026-09-04 row): the ` -- -` marker appended AFTER the pattern never
// suppresses the `["."]` default, because Rst consumes `--` only while `!k && !v`, and `v`
// becomes true the moment the pattern word is seen.
//
// Source executable:  ~/.local/share/claude/versions/2.1.259  (a single ~216MB binary)
// SHA-256:            f7dd62ae415378018cd21dd950eb3bac174ab085830304d3b8b098146bfd47b6
// Located by content (structural anchors, not minified names — those churn every build):
//   grep-family option set  '"--exclude-dir","--include-dir"'   (exactly 1 occurrence)
//   rg option set           '"-T","--type-not"'                  (exactly 1 occurrence)
//   Rst head                'function Rst(e,n,r=[]){'            (byte offset 184041596)
// Consumer: tests/probes/probe-cc-grep-operand-extractor.sh (fixture cells run these
// functions; the live-drift cells re-extract the same functions from the newest INSTALLED
// build by the anchors above and must agree).
//
// Minified identifiers are kept as-is inside the verbatim block below so the fixture can be
// diffed byte-for-byte against a re-extraction. Normalised names are exported at the bottom.
//
// ---- BEGIN VERBATIM (2.1.259) ------------------------------------------------------------
function Rst(e,n,r=[]){let o=[],d=!1,p=!1,y=!1,k=!1,v=!1;for(let x=0;x<e.length;x++){let F=e[x];if(F===void 0||F===null)continue;if(!k&&!v&&F==="--"){k=!0;continue}if(!k&&!v&&F!=="-"&&F.startsWith("-")){let B=F.indexOf("="),U=B>=0?F.slice(0,B):F;if(["-e","--regexp","-f","--file"].includes(U)){if(d=!0,U==="-f"||U==="--file"){let G=B>=0?F.slice(B+1):e[x+1];if(G)o.push(G)}}if(/^-[a-zA-Z]*f$/.test(U)&&U!=="-f"&&B<0&&e[x+1]!==void 0){d=!0,o.push(e[x+1]),x++;continue}if(["--exclude-from","--include-from","--ignore-file"].includes(U)){let G=B>=0?F.slice(B+1):e[x+1];if(G)o.push(G);if(B<0)x++;continue}if(B<0){let G=Pst(F,["-f","--file"]);if(G!==void 0){d=!0,o.push(G);continue}if(F.length>2&&F.startsWith("-e")){d=!0;continue}if(/^-[^-]./.test(F)){let K=!1;for(let pe=1;pe<F.length-1&&!K;pe++){let me=`-${F[pe]}`;if(!n.has(me))continue;if(K=!0,me==="-f")d=!0,o.push(F.slice(pe+1));else if(me==="-e")d=!0}if(K)continue}}let j=B<0&&/^-[^-]./.test(F)?`-${F.at(-1)}`:void 0;if(B<0&&(n.has(U)||j!==void 0&&n.has(j))){if(j==="-e")d=!0;else if(j==="-f"&&e[x+1]!==void 0)d=!0,o.push(e[x+1]);x++}continue}if(v&&!k){let B=Pst(F,["-f","--file"]);if(B!==void 0)o.push(B)}if(v=!0,!d){d=!0;continue}o.push(F),p||=k||!F.startsWith("-")&&!y&&F!=="("&&F!==")",y=!k&&F.startsWith("-")&&!F.includes("=")&&(n.has(F)||/^-[^-]./.test(F)&&n.has(`-${F.at(-1)}`))}return p?o:[...o,...r]}function Pst(e,n){if(!e.startsWith("-"))return;let r=e.indexOf("=");if(r>=0){if(n.includes(e.slice(0,r)))return e.slice(r+1);return}for(let o of n)if(o.length===2&&o[0]==="-"&&e.startsWith(o)&&e!==o)return e.slice(2);return}var Ast=(e)=>{let n=new Set(["-e","--regexp","-f","--file","--exclude","--include","--exclude-dir","--include-dir","-m","--max-count","-A","--after-context","-B","--before-context","-C","--context","-d","--directories"]),o=(e.includes("--")?e.slice(0,e.indexOf("--")):e).some((d)=>/^-[^-]*[rR]/.test(d)||d==="--recursive"||/^(-d|--directories)/.test(d));return Rst(e,n,o?["."]:[])}
// ---- END VERBATIM ------------------------------------------------------------------------

// The rg call site, verbatim: the option set rg hands Rst, and the unconditional ["."] default
// (grep's Ast passes ["."] only when the command is recursive; rg always does).
//   rg:(e)=>Rst(e,new Set(["-e","--regexp","-f","--file","-t","--type","-T","--type-not","-g","--glob","-m","--max-count","--max-depth","-r","--replace","-A","--after-context","-B","--before-context","-C","--context"]),["."])
var RG_OPTION_SET = new Set(["-e","--regexp","-f","--file","-t","--type","-T","--type-not","-g","--glob","-m","--max-count","--max-depth","-r","--replace","-A","--after-context","-B","--before-context","-C","--context"]);
var rg = (e) => Rst(e, RG_OPTION_SET, ["."]);

module.exports = {
  version: "2.1.259",
  sha256: "f7dd62ae415378018cd21dd950eb3bac174ab085830304d3b8b098146bfd47b6",
  extractOperands: Rst,      // Rst(argv, optionSet, defaultOperands) -> string[]
  optionValue: Pst,          // Pst(word, ["-f","--file"]) -> attached value or undefined
  grepFamily: Ast,           // Ast(argv) -> operands, ["."] default only when recursive
  rg: rg,                    // rg(argv)  -> operands, ["."] default unconditionally
  rgOptionSet: RG_OPTION_SET,
};
