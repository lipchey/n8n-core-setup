# Glossary

| Term | Meaning here |
| --- | --- |
| Template | This reusable public GitHub repository, used through **Use this template** |
| Project | Your private repository created from the template; one repository manages one n8n instance |
| Deployment host | The single Debian/Ubuntu x86 VPS created at DigitalOcean or Hetzner, managed over SSH as root |
| Overlay | An additional Compose file layered over a base stack; this template ships only the base Compose stack |
| Initialization | Running the wizard in your existing project checkout to configure its server, secrets, and deployment |
| Deployment | Applying runtime changes from the project's `main` branch through GitHub Actions |
| Workflow export | Reading n8n workflow JSON back into Git after a UI publish/activation event |
| Domain mode A | Prefixing the project name to your common domain |
| Domain mode B | Using the configured project hostname as-is |
| Local backup | Encrypted restic storage on the same VPS as n8n; it shares that server's failure boundary |
| Offsite backup | The optional second restic copy in Backblaze B2 |

See [setup](setup.md), [configuration](configuration.md), and
[operations](operations.md) for the corresponding procedures.
