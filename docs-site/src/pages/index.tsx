import Link from '@docusaurus/Link';
import Layout from '@theme/Layout';
import CodeBlock from '@theme/CodeBlock';
import styles from './index.module.css';

const createCommands = `npm create krf@latest my-game
cd my-game
npm install
npm run dev`;

const chapters = [
  {title: 'Create a KRF project', to: '/tutorial/create-the-project'},
  {title: 'Gather Qi', to: '/tutorial/gather-qi'},
  {title: 'Meditate', to: '/tutorial/meditate'},
  {title: 'Break through', to: '/tutorial/break-through'},
  {title: 'Show realms to everyone', to: '/tutorial/show-realms'},
  {title: 'Join a sect', to: '/tutorial/join-a-sect'},
  {title: 'Test the game', to: '/tutorial/test-the-game'},
];

export default function Home() {
  return (
    <Layout
      title="Kevin's Roblox Framework"
      description="A reusable combat and RPG framework for anime-inspired Roblox games.">
      <main>
        <header className={styles.hero}>
          <div className={styles.heroInner}>
            <div className={styles.intro}>
              <h1>Kevin's Roblox Framework</h1>
              <p className={styles.mission}>
                A reusable combat and RPG framework for anime-inspired Roblox games. KRF solves the
                hard runtime and architecture problems, so you can focus on lore, visuals and game
                feel.
              </p>
              <div className={styles.actions}>
                <Link className="button button--primary button--lg" to="/reference/">
                  Read the docs
                </Link>
                <Link className="button button--primary button--outline button--lg" to="/tutorial/">
                  Start the tutorial
                </Link>
              </div>
            </div>
          </div>
        </header>

        <div className={styles.paths}>
          <section className={styles.path} aria-labelledby="new-to-krf">
            <h2 id="new-to-krf">New to KRF?</h2>
            <p>
              The tutorial builds a small Chinese cultivation game. Each chapter adds one mechanic
              and the KRF systems behind it.
            </p>
            <ol className={styles.chapters}>
              {chapters.map((chapter) => (
                <li key={chapter.to}>
                  <Link to={chapter.to}>{chapter.title}</Link>
                </li>
              ))}
            </ol>
          </section>

          <section className={styles.path} aria-labelledby="create-project">
            <h2 id="create-project">Create a KRF project</h2>
            <p>
              You need Node.js 22.12 or later and Roblox Studio. These commands create the project,
              install its tools and open it in Studio.
            </p>
            <CodeBlock language="bash">{createCommands}</CodeBlock>
          </section>
        </div>
      </main>
    </Layout>
  );
}
