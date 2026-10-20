#!/bin/zsh
# Builds the demo stage in ~/KabukDemo: a small git repo, a separate Kabuk support folder
# with some command history, and the compiled debug client. Safe to run again.
set -e
repo=${0:A:h:h:h}
demo=${KABUK_DEMO_ROOT:-$HOME/KabukDemo}
project=$demo/acme-web

rm -rf $demo $HOME/.kabuk/worktrees/acme-web
mkdir -p $demo/{support,debug,data,codex} $project/{src,server}

swiftc -O $repo/scripts/kabuk-debug.swift -o $demo/kdbg 2> /dev/null

cd $project
git init -q -b main
git config user.name "Acme Dev"
git config user.email "dev@acme.dev"

cat > package.json <<'EOF'
{
  "name": "acme-web",
  "version": "1.4.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "test": "vitest run",
    "deploy": "vite build && wrangler deploy"
  }
}
EOF
cat > README.md <<'EOF'
# Acme Web

The storefront: React on Vite, with a small Express API in `server/`.
EOF
print -l node_modules dist '.env*' '!.env.example' > .gitignore
print -r -- 'VITE_STRIPE_KEY=pk_test_replace_me' > .env.example
git add -A && git commit -qm "Scaffold Acme storefront"

cat > src/theme.ts <<'EOF'
export type Mode = "light";

export const palette = {
  light: { background: "#ffffff", surface: "#f4f4f7", text: "#16161d", accent: "#5b5bd6" },
};

export function applyTheme() {
  const colors = palette.light;
  for (const [name, value] of Object.entries(colors)) {
    document.documentElement.style.setProperty(`--${name}`, value);
  }
}
EOF
cat > src/App.tsx <<'EOF'
import { Cart } from "./cart";
import { Checkout } from "./Checkout";

export default function App() {
  return (
    <main className="app">
      <h1>Acme</h1>
      <Cart />
      <Checkout />
    </main>
  );
}
EOF
cat > src/config.ts <<'EOF'
const apiUrl = import.meta.env.VITE_API_URL;

export const config = {
  apiUrl: apiUrl!,
  currency: "USD",
};
EOF
cat > src/cart.ts <<'EOF'
export type Item = { id: string; name: string; price: number };
export type CartState = { items: (Item & { quantity: number })[] };

export function addItem(state: CartState, item: Item): CartState {
  const existing = state.items.find((i) => i.id === item.id);
  if (existing) {
    return { items: state.items.map((i) => (i.id === item.id ? { ...i, quantity: i.quantity + 1 } : i)) };
  }
  return { items: [...state.items, { ...item, quantity: 1 }] };
}

export function removeItem(state: CartState, id: string): CartState {
  return { items: state.items.filter((i) => i.id !== id) };
}

export function total(state: CartState): number {
  return state.items.reduce((sum, i) => sum + i.price * i.quantity, 0);
}
EOF
git add -A && git commit -qm "Add cart, theme and config"

cat > src/Checkout.tsx <<'EOF'
import { useState } from "react";

export function Checkout() {
  const [email, setEmail] = useState("");
  const [card, setCard] = useState("");
  const [zip, setZip] = useState("");
  const [error, setError] = useState("");

  function submit() {
    if (!/^\S+@\S+\.\S+$/.test(email)) return setError("Enter a valid email");
    if (card.replace(/\s/g, "").length !== 16) return setError("Card number has 16 digits");
    if (!/^\d{5}$/.test(zip)) return setError("ZIP is 5 digits");
    setError("");
    console.log("paying", { email, card, zip });
  }

  return (
    <form onSubmit={(e) => (e.preventDefault(), submit())}>
      <input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="email" />
      <input value={card} onChange={(e) => setCard(e.target.value)} placeholder="card" />
      <input value={zip} onChange={(e) => setZip(e.target.value)} placeholder="zip" />
      {error && <span className="error">{error}</span>}
      <button>Pay</button>
    </form>
  );
}
EOF
cat > server/routes.ts <<'EOF'
import { Router } from "express";
import { listProducts, getProduct } from "./products";
import { login, logout } from "./auth";

export const routes = Router();

routes.get("/api/products", listProducts);
routes.get("/api/products/:id", getProduct);
routes.post("/api/login", login);
routes.post("/api/logout", logout);
EOF
git add -A && git commit -qm "Checkout form and API routes"

# Command history from the past week, so ⌘R has something to find.
now=$(date +%s)
reference=978307200  # Foundation dates count from 2001-01-01
seed=(
  "docker compose up -d postgres redis|6"
  "docker compose logs -f api|5.8"
  "npx prisma migrate dev --name add_orders|5.2"
  "curl -s localhost:8787/api/products | jq '.[0]'|4.6"
  "docker build -t acme-web:1.4.0 .|3.9"
  "git rebase -i main|3.1"
  "kubectl get pods -n staging|2.7"
  "docker run --rm -p 8080:80 acme-web:1.4.0|2.2"
  "npm run lint -- --fix|1.6"
  "gh pr create --fill|1.1"
  "git log --oneline --graph -15|0.7"
  "docker system prune -af|0.3"
)
for entry in $seed; do
  command=${entry%|*} days=${entry##*|}
  date=$(printf %.0f $(( now - reference - days * 86400 )))
  command=${command//\\/\\\\}
  command=${command//\"/\\\"}
  print -r -- "{\"command\":\"$command\",\"cwd\":\"$project\",\"date\":$date}" >> $demo/support/history.jsonl
done

print "Demo stage ready in $demo"
