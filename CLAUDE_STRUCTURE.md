# `.claude` 目录结构说明

这份文档解释仓库根目录下 `.claude/` 相关文件各自的作用，以及哪些是 Claude Code 官方机制、哪些是本仓库自己发明的约定。写这份文档是因为部分目录（`rules/`、`workflows/`、`agent-memory/`）容易被误认为官方自动加载的东西，实际上不是——用之前先搞清楚谁会自动读、谁需要手动引用。

## 官方机制（Claude Code 会自动识别）

| 路径 | 作用 | 加载方式 |
|------|------|----------|
| `CLAUDE.md` | 项目级指令，进这个仓库时自动读入上下文 | 自动 |
| `.mcp.json` | 项目范围的 MCP server 配置 | 自动（当前为空，本仓库不需要外部 MCP server） |
| `.worktreeinclude` | 创建新 worktree 时，即使被 gitignore 也要一起复制的文件清单 | 自动（`EnterWorktree` 时读取） |
| `.claude/settings.json` | 团队共享的项目设置：权限白名单、hooks 等 | 自动 |
| `.claude/settings.local.json` | 个人本地设置，覆盖/追加 `settings.json`，已加进 `.gitignore` 不提交 | 自动 |
| `.claude/commands/*.md` | 自定义 slash command（如 `/fix-issue`），支持 `$ARGUMENTS` | 输入 `/fix-issue ...` 时加载 |
| `.claude/agents/*.md` | 自定义 subagent 定义（如 `code-reviewer`），frontmatter 里写 `name`/`description`/`tools` | 通过 Agent 工具按名字调用，或被自动匹配 |
| `.claude/output-styles/*.md` | 自定义输出风格（如 `rtl-reviewer`） | 通过 `/output-style` 或配置项启用 |
| `.claude/skills/<name>/SKILL.md` | Agent Skills：一段可复用的操作指南，frontmatter 里的 `description` 决定何时被自动匹配 | 满足触发条件时自动加载，或显式 `/skill-name` 调用 |

## 本仓库自定义的约定（不会被自动加载，需要显式引用）

| 路径 | 作用 | 谁来引用 |
|------|------|----------|
| `.claude/rules/testing.md`<br>`.claude/rules/api-design.md` | 项目特有的规则文档（测试规范、模块接口/总线协议规范） | 通过 `CLAUDE.md` 里的 `@.claude/rules/xxx.md` 语法手动拉入上下文——**这是唯一让它们生效的方式**，`rules/` 目录本身不是 Claude Code 认识的保留目录名 |
| `.claude/workflows/add-peripheral.md` | 给人和 agent 看的操作手册（比如"如何加一个新外设"的 9 步流程） | 没有自动加载机制，靠 `rules/api-design.md` 里的 `[[add-peripheral]]` 链接手动指路，或者你/我在对话里主动打开读 |
| `.claude/agent-memory/<agent-name>/MEMORY.md` | 给某个 subagent 预埋的背景知识（比如 `code-reviewer` 该知道哪些历史 bug 已经修过，不要重复报告） | **注意**：这不是我真正的持久记忆系统（那个在 `~/.claude/projects/.../memory/`，运行时自动维护，退出会话后还在）。这里的 `agent-memory/` 是仿照你截图里的目录结构、写进这个仓库里跟代码一起提交的**静态文档**，需要在 subagent 的 prompt 里显式告诉它去读这个文件，它才会知道 |

## 目前没有的东西

- **hooks**：`settings.json` 里还没有 `hooks` 字段，仓库里也没有 `.claude/hooks/` 目录。如果之后要加自动化钩子（比如每次写文件后自动跑 `iverilog` 检查），应该往 `settings.json` 加 `"hooks"` 键，不需要新建文件夹。
- **`.claude/output-styles/`、`.claude/workflows/` 目前各自只有一个文件**，图里展示的折叠状态在这个仓库里就是"内容比较少但存在"，不代表标准数量。
