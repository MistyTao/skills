#!/usr/bin/env node
const db = require('./db');

function parseArgs(args) {
  const options = {};
  let currentFlag = null;
  const positionals = [];
  
  for (let i = 2; i < args.length; i++) {
    const arg = args[i];
    if (arg.startsWith('--')) {
      currentFlag = arg.slice(2);
      options[currentFlag] = true;
    } else if (arg.startsWith('-')) {
      currentFlag = arg.slice(1);
      options[currentFlag] = true;
    } else {
      if (currentFlag) {
        options[currentFlag] = arg;
        currentFlag = null;
      } else {
        positionals.push(arg);
      }
    }
  }
  return { options, positionals };
}

// 格式化时间戳差值为可读的“剩余休眠时间”
function formatRemainingSleep(ms) {
  if (ms <= 0) return '已唤醒';
  const totalSecs = Math.floor(ms / 1000);
  const secs = totalSecs % 60;
  const totalMins = Math.floor(totalSecs / 60);
  const mins = totalMins % 60;
  const totalHours = Math.floor(totalMins / 60);
  const hours = totalHours % 24;
  const days = Math.floor(totalHours / 24);

  if (days > 0) return `${days}天${hours}小时`;
  if (hours > 0) return `${hours}小时${mins}分`;
  if (mins > 0) return `${mins}分${secs}秒`;
  return `${secs}秒`;
}

// 翻译状态展示
function translateStatus(displayStatus) {
  switch (displayStatus) {
    case 'pending_confirmation': return '⏰ 待确认';
    case 'sleeping': return '💤 休眠中';
    case 'completed': return '✅ 已完成';
    default: return '未知';
  }
}

function formatResources(resources) {
  if (!resources || resources.length === 0) return '-';
  return resources.map((r, index) => {
    let label = `资源${index + 1}`;
    if (r.includes('jira.')) label = 'Jira';
    else if (r.includes('gitlab.')) label = 'GitLab';
    else if (r.includes('feishu.cn') || r.includes('larksuite.com')) label = '飞书';
    else if (r.includes('github.com')) label = 'GitHub';
    return `[${label}](${r})`;
  }).join(', ');
}

function printUsage() {
  console.log(`
使用说明: node tasks-cli.js <command> [options]

命令列表:
  add                     录入新任务
    --desc "任务描述"      (必填)
    --type "任务类型"      (选填，默认: 其他)
    --deadline "截止时间"  (选填，默认: 未设置)
    --goal "当前目标"      (选填，默认: 未设置)
    --resources "资源1,资源2" (选填，关联的各种资源/链接，用逗号分隔)
    --sleep "休眠时间"     (选填，例如 30s, 10m, 2h, 1d，默认: 0s，即立即唤醒)

  list-pending            查看所有已过休眠期、等待确认进度的任务
  
  list-all                查看所有任务（包含休眠中与已完成任务）

  confirm                 二次确认进度，更新任务状态并使其重新进入休眠
    --id "任务ID"          (必填，如 T1)
    --progress "进度"      (选填，0-100 的整数)
    --goal "下一阶段目标"  (选填)
    --resources "新资源1,新资源2" (选填，重置关联资源，用逗号分隔)
    --sleep "继续休眠时间" (选填，不指定则清除休眠，立即可查)

  complete                标记任务已完成，记录最终总结
    --id "任务ID"          (必填，如 T1)
    --summary "工作量总结" (必填，汇总的工作量细节)

  report                  生成今日（或指定日期）的已完成任务日报汇总
    --date "YYYY-MM-DD"    (选填，默认今天)
`);
}

function main() {
  const { options, positionals } = parseArgs(process.argv);
  const command = positionals[0];

  if (!command) {
    printUsage();
    process.exit(0);
  }

  try {
    switch (command.toLowerCase()) {
      case 'add': {
        const desc = options.desc || options.d;
        if (!desc || typeof desc !== 'string') {
          console.error('错误: 新增任务必须指定描述 --desc "任务描述"');
          process.exit(1);
        }
        const type = options.type || options.t || '其他';
        const deadline = options.deadline || options.dl || '未设置';
        const goal = options.goal || options.g || '未设置';
        const sleep = options.sleep || options.s || '0s';
        const resources = options.resources || options.r;

        const task = db.addTask(desc, type, deadline, goal, sleep, resources);
        console.log(`成功创建任务 **${task.id}**!`);
        console.log(`- **类型**: ${task.type}`);
        console.log(`- **描述**: ${task.description}`);
        console.log(`- **当前目标**: ${task.current_goal}`);
        console.log(`- **关联资源**: ${formatResources(task.resources)}`);
        console.log(`- **休眠至**: ${new Date(task.sleep_until).toLocaleString('zh-CN')} (${sleep})`);
        break;
      }

      case 'list-pending': {
        const tasks = db.getTasks('pending');
        if (tasks.length === 0) {
          console.log('✅ 目前没有需要二次确认进度的任务（全部任务都在休眠中或已完成）。');
          break;
        }

        console.log('### ⏰ 待二次确认进度的任务');
        console.log('| ID | 类型 | 任务描述 | 截止时间 | 当前进度 | 当前目标 | 关联资源 |');
        console.log('| :--- | :--- | :--- | :--- | :--- | :--- | :--- |');
        tasks.forEach(t => {
          console.log(`| **${t.id}** | ${t.type} | ${t.description} | ${t.deadline} | \`${t.progress}%\` | ${t.current_goal} | ${formatResources(t.resources)} |`);
        });
        break;
      }

      case 'list-all': {
        const tasks = db.getTasks('all');
        if (tasks.length === 0) {
          console.log('目前没有记录任何任务，请使用 `add` 命令添加。');
          break;
        }

        console.log('### 📋 所有任务状态一览表');
        console.log('| ID | 状态 | 类型 | 任务描述 | 进度 | 当前目标 | 关联资源 | 休眠剩余 / 完成时间 | 截止时间 |');
        console.log('| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |');
        tasks.forEach(t => {
          let timeInfo = '-';
          if (t.display_status === 'sleeping') {
            timeInfo = `💤 剩 ${formatRemainingSleep(t.remaining_sleep_ms)}`;
          } else if (t.display_status === 'pending_confirmation') {
            timeInfo = '⏰ 已唤醒';
          } else if (t.display_status === 'completed' && t.completed_at) {
            timeInfo = `✅ ${new Date(t.completed_at).toLocaleDateString('zh-CN')} ${new Date(t.completed_at).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}`;
          }

          console.log(`| **${t.id}** | ${translateStatus(t.display_status)} | ${t.type} | ${t.description} | \`${t.progress}%\` | ${t.current_goal} | ${formatResources(t.resources)} | ${timeInfo} | ${t.deadline} |`);
        });
        break;
      }

      case 'confirm': {
        const id = options.id || options.i;
        if (!id || typeof id !== 'string') {
          console.error('错误: 确认进度必须指定任务 ID --id "任务ID" (例如 T1)');
          process.exit(1);
        }
        const progress = options.progress || options.p;
        const goal = options.goal || options.g;
        const sleep = options.sleep || options.s;
        const resources = options.resources || options.r;

        const task = db.confirmProgress(id, progress, goal, sleep, resources);
        console.log(`任务 **${task.id}** 进度已确认更新!`);
        console.log(`- **当前进度**: \`${task.progress}%\``);
        console.log(`- **当前目标**: ${task.current_goal}`);
        console.log(`- **关联资源**: ${formatResources(task.resources)}`);
        if (task.status === 'active' && task.sleep_until > Date.now()) {
          const rem = task.sleep_until - Date.now();
          console.log(`- **再次进入休眠**: 剩余 ${formatRemainingSleep(rem)} (唤醒时间: ${new Date(task.sleep_until).toLocaleString('zh-CN')})`);
        } else {
          console.log(`- **状态**: 立即处于待确认状态`);
        }
        break;
      }

      case 'complete': {
        const id = options.id || options.i;
        const summary = options.summary || options.s;

        if (!id || typeof id !== 'string') {
          console.error('错误: 标记完成必须指定任务 ID --id "任务ID" (例如 T1)');
          process.exit(1);
        }
        if (!summary || typeof summary !== 'string') {
          console.error('错误: 标记完成必须指定具体工作总结 --summary "工作量描述"');
          process.exit(1);
        }

        const task = db.completeTask(id, summary);
        console.log(`🎉 任务 **${task.id}** 已成功标记为“已完成”！`);
        console.log(`- **任务描述**: ${task.description}`);
        console.log(`- **工作量总结**: ${task.workload_summary}`);
        console.log(`- **归档时间**: ${new Date(task.completed_at).toLocaleString('zh-CN')}`);
        break;
      }

      case 'report': {
        const date = options.date || options.d;
        const reportText = db.generateDailyReport(date);
        console.log(reportText);
        break;
      }

      default:
        console.error(`未知命令: "${command}"`);
        printUsage();
        process.exit(1);
    }
  } catch (err) {
    console.error(`执行出错: ${err.message}`);
    process.exit(1);
  }
}

main();
