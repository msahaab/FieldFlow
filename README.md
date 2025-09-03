# FieldFlow Assessment

## Overview
FieldFlow is an internal operations management system designed to help teams such as Sales, Technicians, and Admins manage and track their operations efficiently. The system focuses on job lifecycle modeling, allowing users to create, manage, and monitor jobs through a series of structured tasks. Each job can be linked to various assets, such as equipment or tools, ensuring that all necessary resources are accounted for.

## Getting Started

### Clone the Repository
First, clone the repository using the following command:

```bash
git clone https://github.com/msahaab/FieldFlowAssessment.git
```

### Navigate to the Project Directory
Change into the project directory:

```bash
cd FieldFlowAssessment
```

### Run Docker Commands
To build and run the server, use the following Docker commands:

1. Build the Docker images:

```bash
docker-compose build
```

2. Start the Docker containers:

```bash
docker-compose up
```

### Run a Test
After the server is running, you can run tests with the following command:

```bash
docker-compose run --rm app python manage.py test
```

### Access the API Documentation
Launch the server and access the API documentation at:

[http://127.0.0.1:8000/api/docs/](http://127.0.0.1:8000/api/docs/)

## Conclusion
This README provides a quick guide to get started with the FieldFlow Assessment project. The system is designed to streamline operations and improve efficiency for internal teams. For further details, please refer to the project's documentation or reach out for support.