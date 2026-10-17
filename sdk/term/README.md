# @libfx/term

The fx terminal for [libfx](https://www.npmjs.com/package/libfx): the fx CLI's interface compiled to WebAssembly, for a page or a Node.js process to run in an xterm.js terminal. It carries `fx-term.wasm`, so apps that only run agents don't download it.

```sh
npm install libfx @libfx/term
```

```js
import { createFxTerminal, xtermAdapter } from "@libfx/term";

const terminal = await createFxTerminal({
  terminal: xtermAdapter(term), // an xterm.js Terminal
  env: { AI_GATEWAY_API_KEY: shortLivedKey },
});

await terminal.interactive;
```

`createFxTerminal()` is libfx's, with `wasm` set to this package's `fx-term.wasm`, and takes the same options. Install the same version of `libfx` and `@libfx/term`. See [Terminal](https://fx.sh/docs/lib/terminal).

## License

[Apache-2.0](https://github.com/vercel-labs/fx/blob/main/LICENSE)
