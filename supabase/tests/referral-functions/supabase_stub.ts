// Substitut LOCAL de supabase-js pour exécuter les fonctions serveur contre la base de test.
// Clé de service => droits propriétaire ; sinon jeton « Bearer <uuid> » => rôle authenticated + identité.
import pg from 'npm:pg@8.11.3';
const pool = new pg.Pool({ host: Deno.env.get('PGHOST') || '/var/tmp/hvpg', port: Number(Deno.env.get('PGPORT') || 54329), user: 'postgres', database: Deno.env.get('PGDATABASE') || 'hv_t', max: 4 });
const STORE = Deno.env.get('HV_TEST_STORAGE') || '/tmp/hv-referral-storage';
type Res = { data: any; error: any };
async function exec(uid: string | null, sql: string, params: any[]): Promise<Res> {
  const c = await pool.connect();
  try {
    await c.query('begin');
    if (uid) { await c.query("select set_config('request.jwt.claim.sub', $1, true), set_config('request.jwt.claim.role', 'authenticated', true)", [uid]); await c.query('set local role authenticated'); }
    const r = await c.query(sql, params);
    await c.query('commit');
    return { data: r.rows, error: null };
  } catch (e) { await c.query('rollback').catch(() => {}); return { data: null, error: { message: (e as Error).message, code: (e as any).code } }; }
  finally { c.release(); }
}
function builder(uid: string | null, table: string) {
  let op = 'select', values: any = null; const where: [string, any][] = []; let ret = false;
  const run = async (single: boolean): Promise<Res> => {
    const p: any[] = []; const w = where.map(([k, v]) => { p.push(v); return `${k} = $${p.length}`; }).join(' and ');
    let sql = '';
    if (op === 'insert') { const ks = Object.keys(values); ks.forEach(k => p.push(values[k])); sql = `insert into public.${table} (${ks.join(',')}) values (${ks.map((_, i) => '$' + (i + 1)).join(',')})`; }
    else if (op === 'update') { const ks = Object.keys(values); const base = p.length; ks.forEach(k => p.push(values[k])); sql = `update public.${table} set ${ks.map((k, i) => `${k} = $${base + i + 1}`).join(', ')}` + (w ? ` where ${w}` : ''); }
    else sql = `select * from public.${table}` + (w ? ` where ${w}` : '');
    if (ret || op === 'select') sql += op === 'select' ? '' : ' returning *';
    const r = await exec(uid, sql, p);
    if (r.error) return { data: null, error: { ...r.error, code: r.error.code } };
    return { data: single ? (r.data[0] || null) : r.data, error: null };
  };
  const q: any = {
    insert(v: any) { op = 'insert'; values = v; return q; },
    update(v: any) { op = 'update'; values = v; return q; },
    select(_c?: string) { ret = true; return q; },
    eq(k: string, v: any) { where.push([k, v]); return q; },
    maybeSingle() { return run(true); },
    then(a: any, b: any) { return run(false).then(a, b); },
  };
  return q;
}
export function createClient(_url: string, key: string, opts: any = {}) {
  const auth = opts?.global?.headers?.Authorization || '';
  const uid = key === 'service' ? null : (auth.replace(/^Bearer\s+/, '') || null);
  return {
    async rpc(name: string, args: Record<string, any> = {}): Promise<Res> {
      if (key !== 'service' && !uid) return { data: null, error: { message: 'JWT requis' } };
      const ks = Object.keys(args); const sql = `select public.${name}(${ks.map((k, i) => `${k} := $${i + 1}`).join(', ')}) as r`;
      const r = await exec(uid, sql, ks.map(k => args[k]));
      return r.error ? r : { data: r.data[0].r, error: null };
    },
    from(t: string) { return builder(uid, t); },
    storage: { from(bucket: string) { return {
      async upload(path: string, bytes: Uint8Array) { const f = `${STORE}/${bucket}/${path}`; await Deno.mkdir(`${STORE}/${bucket}`, { recursive: true });
        try { await Deno.stat(f); return { error: { message: 'The resource already exists' } }; } catch { await Deno.writeFile(f, bytes); return { error: null }; } },
      async download(path: string) { try { return { data: new Blob([await Deno.readFile(`${STORE}/${bucket}/${path}`)]), error: null }; } catch { return { data: null, error: { message: 'not found' } }; } },
    }; } },
  };
}
export async function closePool() { await pool.end(); }
export const sql = (q: string, p: any[] = []) => exec(null, q, p);
