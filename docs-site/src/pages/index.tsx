import Link from '@docusaurus/Link';
import Layout from '@theme/Layout';
import CodeBlock from '@theme/CodeBlock';
import styles from './index.module.css';

export default function Home() {
  return (
    <Layout
      title="Kevin's Roblox Framework"
      description="A reusable combat and RPG framework for anime-inspired Roblox games.">
      <main className={styles.home}>
        <h1>Kevin's Roblox Framework</h1>
        <p className={styles.mission}>
          KRF is a reusable combat and RPG framework for anime-inspired Roblox games. It solves the
          hard runtime and architecture problems, so you can focus on lore, visuals and game feel.
        </p>

        <Link className="button button--primary button--lg" to="/reference/">
          Read the docs
        </Link>

        <p className={styles.tutorial}>
          New to KRF? <Link to="/tutorial/">Follow the tutorial</Link>, which builds a small
          cultivation game one chapter at a time.
        </p>

        <h2>Create a KRF project</h2>
        <CodeBlock language="bash">npm create krf@latest my-game</CodeBlock>
      </main>
    </Layout>
  );
}
