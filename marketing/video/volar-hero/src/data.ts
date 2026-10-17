// data.ts — sample content for the hero video. Titles are flavor text (dimmed background rows),
// never read closely by the viewer.
export type Task = {
  id: string;
  title: string;
  time?: string;
  priority?: 'high' | 'med' | 'low';
  dur?: string;
};

export const taskA: Task = {
  id: 'a',
  title: 'Send the deck to Nam',
  time: 'Today 5 PM',
  priority: 'high',
  dur: '15m',
};

export const taskB: Task = {
  id: 'b',
  title: 'Call Linh back — client waiting',
  time: 'Today',
  priority: 'high',
  dur: '10m',
};

export const parkedNote = 'Stopped at slide 7 numbers';

// 28 plausible professional filler rows for the "full list" shot. Deliberately boring/real.
export const fillerTasks: string[] = [
  'Review Q3 budget',
  'Reply to Acme contract',
  'Book dentist',
  'Fix onboarding copy',
  'Approve design review comments',
  'Renew domain registration',
  'Prep slides for board meeting',
  'Follow up with recruiter',
  'Pay office rent',
  'Update employee handbook',
  'Schedule 1:1 with Marcus',
  'Draft Q4 roadmap outline',
  'Review pull request #482',
  'Cancel unused SaaS subscription',
  'Confirm travel for conference',
  'Reconcile expense report',
  'Write release notes v2.3',
  'Call insurance about claim',
  'Order new laptop for Priya',
  'Review vendor invoice',
  'Update investor tracker',
  'Plan team offsite',
  'Respond to support escalation',
  'Sign updated NDA',
  'Backup client database',
  'Review marketing email draft',
  'Tidy up shared drive folders',
  'Draft performance review notes',
];

export const captions = {
  sayItOnce: 'Say it once.',
  picksNext: 'Volar picks what’s next.',
  parkResume: 'Park it. Resume right there.',
  manyWays: 'Many ways in. One list.',
} as const;

export const transcriptSentence = "Send the deck to Nam before 5, it's urgent";
