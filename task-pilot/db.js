const fs = require('node:fs');
const path = require('node:path');

const DB_PATH = path.resolve(__dirname, 'tasks.json');

// 解析休眠周期字符串为毫秒数
function parseSleepPeriod(period) {
  if (!period) return 0;
  const match = period.match(/^(\d+)([smhd])$/);
  if (!match) {
    throw new Error(`无效的休眠周期格式: "${period}"。请使用如: 10s, 30m, 2h, 1d`);
  }
  const value = parseInt(match[1], 10);
  const unit = match[2];
  switch (unit) {
    case 's': return value * 1000;
    case 'm': return value * 60 * 1000;
    case 'h': return value * 60 * 60 * 1000;
    case 'd': return value * 24 * 60 * 60 * 1000;
    default: return 0;
  }
}

// 读取任务数据
function readTasks() {
  try {
    if (!fs.existsSync(DB_PATH)) {
      fs.writeFileSync(DB_PATH, JSON.stringify([], null, 2), 'utf8');
      return [];
    }
    const content = fs.readFileSync(DB_PATH, 'utf8');
    return JSON.parse(content || '[]');
  } catch (err) {
    console.error('读取任务数据库失败，已重置为空数组:', err.message);
    return [];
  }
}

// 写入任务数据
function writeTasks(tasks) {
  fs.writeFileSync(DB_PATH, JSON.stringify(tasks, null, 2), 'utf8');
}

// 动态获取任务的展示状态
function getTaskDisplayStatus(task) {
  if (task.status === 'completed') {
    return 'completed';
  }
  const now = Date.now();
  if (task.sleep_until && task.sleep_until > now) {
    return 'sleeping';
  }
  return 'pending_confirmation';
}

// 新增任务
function addTask(description, type, deadline, current_goal, sleep_period, resources) {
  const tasks = readTasks();
  
  // 生成短 ID (例如 T1, T2...)
  let nextNum = 1;
  if (tasks.length > 0) {
    const ids = tasks.map(t => {
      const match = t.id.match(/^T(\d+)$/);
      return match ? parseInt(match[1], 10) : 0;
    });
    nextNum = Math.max(...ids) + 1;
  }
  const id = `T${nextNum}`;

  const sleepMs = parseSleepPeriod(sleep_period);
  const sleepUntil = Date.now() + sleepMs;

  let resourceList = [];
  if (resources) {
    if (Array.isArray(resources)) {
      resourceList = resources;
    } else if (typeof resources === 'string') {
      resourceList = resources.split(',').map(r => r.trim()).filter(Boolean);
    }
  }

  const newTask = {
    id,
    description: description.trim(),
    type: (type || '其他').trim(),
    deadline: (deadline || '未设置').trim(),
    progress: 0,
    current_goal: (current_goal || '未设置').trim(),
    resources: resourceList,
    sleep_until: sleepUntil,
    status: 'active',
    created_at: new Date().toISOString(),
    completed_at: null,
    workload_summary: null
  };

  tasks.push(newTask);
  writeTasks(tasks);
  return newTask;
}

// 二次确认进度
function confirmProgress(id, progress, next_goal, sleep_period, resources) {
  const tasks = readTasks();
  const task = tasks.find(t => t.id.toLowerCase() === id.toLowerCase());
  
  if (!task) {
    throw new Error(`找不到 ID 为 "${id}" 的任务`);
  }
  if (task.status === 'completed') {
    throw new Error(`任务 "${id}" 已是完成状态，无法修改进度`);
  }

  if (progress !== undefined && progress !== null) {
    const progNum = parseInt(progress, 10);
    if (isNaN(progNum) || progNum < 0 || progNum > 100) {
      throw new Error('进度值必须是 0 到 100 之间的整数');
    }
    task.progress = progNum;
  }

  if (next_goal) {
    task.current_goal = next_goal.trim();
  }

  if (resources !== undefined && resources !== null) {
    if (Array.isArray(resources)) {
      task.resources = resources;
    } else if (typeof resources === 'string') {
      task.resources = resources.split(',').map(r => r.trim()).filter(Boolean);
    }
  }

  if (sleep_period) {
    const sleepMs = parseSleepPeriod(sleep_period);
    task.sleep_until = Date.now() + sleepMs;
  } else {
    // 如果没有指定，默认清理掉 sleep_until 意为立即可查
    task.sleep_until = Date.now();
  }

  writeTasks(tasks);
  return task;
}

// 标记任务完成
function completeTask(id, workload_summary) {
  const tasks = readTasks();
  const task = tasks.find(t => t.id.toLowerCase() === id.toLowerCase());

  if (!task) {
    throw new Error(`找不到 ID 为 "${id}" 的任务`);
  }

  task.status = 'completed';
  task.progress = 100;
  task.completed_at = new Date().toISOString();
  task.workload_summary = (workload_summary || '完成相关工作').trim();
  task.sleep_until = 0; // 完成后不再休眠

  writeTasks(tasks);
  return task;
}

// 获取分类任务列表
function getTasks(filter = 'all') {
  const tasks = readTasks();
  const now = Date.now();

  return tasks.map(t => ({
    ...t,
    display_status: getTaskDisplayStatus(t),
    remaining_sleep_ms: t.status === 'active' && t.sleep_until > now ? t.sleep_until - now : 0
  })).filter(t => {
    if (filter === 'all') return true;
    if (filter === 'pending') return t.display_status === 'pending_confirmation';
    if (filter === 'sleeping') return t.display_status === 'sleeping';
    if (filter === 'completed') return t.display_status === 'completed';
    return true;
  });
}

// 生成日报汇总数据
function generateDailyReport(dateStr) {
  const tasks = readTasks();
  
  // 确定筛选日期，如不传则为今天 (本地日期格式 YYYY-MM-DD)
  let targetDate = dateStr;
  if (!targetDate) {
    const localDate = new Date();
    const year = localDate.getFullYear();
    const month = String(localDate.getMonth() + 1).padStart(2, '0');
    const day = String(localDate.getDate()).padStart(2, '0');
    targetDate = `${year}-${month}-${day}`;
  }

  // 筛选出在 targetDate 完成的任务
  const completedTasksToday = tasks.filter(t => {
    if (t.status !== 'completed' || !t.completed_at) return false;
    const compDate = t.completed_at.split('T')[0]; // YYYY-MM-DD
    return compDate === targetDate;
  });

  if (completedTasksToday.length === 0) {
    return `### 日报数据源 (${targetDate})\n\n> 今日无已完成的任务归档。`;
  }

  // 按任务类型分组
  const grouped = {};
  completedTasksToday.forEach(t => {
    if (!grouped[t.type]) {
      grouped[t.type] = [];
    }
    grouped[t.type].push(t);
  });

  let report = `### 日报数据源 (${targetDate})\n\n`;
  for (const type of Object.keys(grouped)) {
    report += `#### 📂 ${type}\n`;
    grouped[type].forEach(t => {
      report += `- **[${t.id}] ${t.description}**\n`;
      report += `  - **完成时间**: ${new Date(t.completed_at).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}\n`;
      report += `  - **工作量总结**: ${t.workload_summary}\n`;
    });
    report += `\n`;
  }

  return report;
}

module.exports = {
  addTask,
  confirmProgress,
  completeTask,
  getTasks,
  generateDailyReport,
  parseSleepPeriod
};
