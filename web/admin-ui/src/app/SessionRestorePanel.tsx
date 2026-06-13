import { ShieldCheck } from "../components/icons";

export function SessionRestorePanel() {
  return (
    <main className="auth-shell">
      <section className="auth-panel" aria-label="正在恢复管理员会话">
        <div className="auth-brand">
          <span className="brand-mark">FB</span>
          <span>Fubox API</span>
        </div>
        <p className="eyebrow">管理控制台</p>
        <h1>正在恢复会话</h1>
        <p className="muted-copy">正在检查现有管理员访问权限。</p>
      </section>

      <section className="auth-context" aria-label="访问范围">
        <ShieldCheck aria-hidden="true" size={26} />
        <div>
          <h2>受限操作</h2>
          <dl>
            <div>
              <dt>会话</dt>
              <dd>HttpOnly Cookie</dd>
            </div>
            <div>
              <dt>导航</dt>
              <dd>按能力开放</dd>
            </div>
            <div>
              <dt>状态</dt>
              <dd>检查中</dd>
            </div>
          </dl>
        </div>
      </section>
    </main>
  );
}
